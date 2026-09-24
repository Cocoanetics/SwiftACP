#if os(macOS) || os(Linux)
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One command started for a terminal, the way acpx's `spawnAndWait` starts it with
/// Node's `spawn(command, args, {detached: true, stdio: ["ignore", "pipe", "pipe"]})`:
///
/// - in a new session, so it leads its own process group and has no controlling
///   terminal — a command reading `/dev/tty` fails instead of stopping, and nothing it
///   prints reaches the user's terminal;
/// - stdin from `/dev/null`, stdout and stderr each on a pipe;
/// - every signal at its default disposition and none blocked, whatever this process
///   ignores (Swift programs commonly ignore `SIGPIPE`);
/// - found on the `PATH` of the environment it is given, as libuv searches it.
///
/// Output is read on a thread of its own until both pipes close (a background child
/// can keep them open after the command exits) or ``stopReading()``. Another thread
/// waits for the command to exit, has the reader take in everything already in the
/// pipes — all the command wrote before exiting — and only then reaps it and reports
/// the exit, under the same lock as ``send(_:)``: a signal never reaches a process that
/// reused its pid, and output read after the exit is all there.
final class TerminalProcess: @unchecked Sendable {
    /// Why a command could not be started: the errno, named as Node names it.
    struct SpawnError: Error, Equatable {
        let code: Int32
        var name: String { errnoNames[code] ?? "UNKNOWN" }
    }

    let pid: pid_t
    private let outputDescriptors: [Int32]
    /// Written to by ``stopReading()`` to wake the reader out of `poll`.
    private let wake: (read: Int32, write: Int32)
    private let lock = NSLock()
    private var reaped = false
    private var stopped = false
    /// Set by the reader as it leaves, before it closes its descriptors.
    private var readerFinished = false
    /// The waiter's request that the reader empty the pipes, answered on ``drained``.
    private var drainRequested = false
    private let drained = DispatchSemaphore(value: 0)
    /// The reader, until it is started.
    private var pendingReader: Thread?

    private init(pid: pid_t, outputDescriptors: [Int32], wake: (read: Int32, write: Int32)) {
        self.pid = pid
        self.outputDescriptors = outputDescriptors
        self.wake = wake
    }

    // MARK: - Starting

    /// Start `command` with `arguments` in `cwd`. `environment` is the command's whole
    /// environment, its `PATH` included; `nil` passes this process's own.
    ///
    /// - Parameter withoutCloseFrom: for tests, close inherited descriptors as on a
    ///   glibc without `closefrom` (Linux; ignored elsewhere).
    static func spawn(
        command: String, arguments: [String], cwd: String, environment: [String: String]?,
        withoutCloseFrom: Bool = false
    ) throws -> TerminalProcess {
        let variables = environment ?? ProcessInfo.processInfo.environment
        let executable = try resolveExecutable(command, cwd: cwd, path: variables["PATH"])
        let stdout = try makePipe()
        let stderr = try makePipe()
        let wake: (read: Int32, write: Int32)
        do {
            wake = try makePipe()
        } catch {
            [stdout.read, stdout.write, stderr.read, stderr.write].forEach { close($0) }
            throw error
        }
        let pid: pid_t
        do {
            pid = try launch(
                executable, argv: [command] + arguments, cwd: cwd,
                environment: variables.map { "\($0.key)=\($0.value)" },
                stdout: stdout.write, stderr: stderr.write, withoutCloseFrom: withoutCloseFrom)
        } catch {
            [stdout.read, stdout.write, stderr.read, stderr.write, wake.read, wake.write].forEach { close($0) }
            throw error
        }
        close(stdout.write)
        close(stderr.write)
        return TerminalProcess(pid: pid, outputDescriptors: [stdout.read, stderr.read], wake: wake)
    }

    /// Where `command` runs from: as given when it names a path (a relative one is
    /// resolved against `cwd` when the command starts), else the first executable
    /// regular file of that name on `path` (libuv's `/usr/bin:/bin` without one).
    /// Like `execvp`, a match that is not executable is `EACCES` if nothing better
    /// turns up.
    private static func resolveExecutable(_ command: String, cwd: String, path: String?) throws -> String {
        guard !command.isEmpty else { throw SpawnError(code: ENOENT) }
        if command.contains("/") { return command }
        var sawUnexecutable = false
        for directory in (path ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? "." : String(directory)
            let candidate = "\(base)/\(command)"
            let located = base.hasPrefix("/") ? candidate : "\(cwd)/\(candidate)"
            var status = stat()
            guard stat(located, &status) == 0, UInt32(status.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else {
                continue
            }
            if access(located, X_OK) == 0 { return located }
            sawUnexecutable = true
        }
        throw SpawnError(code: sawUnexecutable ? EACCES : ENOENT)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw SpawnError(code: errno) }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        // Only this side's read end: the command's end stays blocking.
        _ = fcntl(descriptors[0], F_SETFL, fcntl(descriptors[0], F_GETFL) | O_NONBLOCK)
        return (descriptors[0], descriptors[1])
    }

    private static func launch(
        _ executable: String, argv: [String], cwd: String, environment: [String],
        stdout: Int32, stderr: Int32, withoutCloseFrom: Bool
    ) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        try addChangeDirectory(&actions, cwd)
        closeInheritedDescriptors(&actions, withoutCloseFrom: withoutCloseFrom)

        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        sigdelset(&everySignal, SIGKILL)
        sigdelset(&everySignal, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        let flags = Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF) | newSessionFlags
        let result = posix_spawnattr_setflags(&attributes, Int16(flags))
        guard result == 0 else { throw SpawnError(code: result) }

        var pid: pid_t = 0
        let status = withCStrings(argv) { argvPointers in
            withCStrings(environment) { environmentPointers in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointers, environmentPointers)
            }
        }
        guard status == 0 else { throw SpawnError(code: status) }
        return pid
    }

    #if canImport(Darwin)
    /// Node's `detached: true` is `setsid()` in the child; Darwin does it at spawn, and
    /// closes every descriptor the file actions did not set up.
    private static let newSessionFlags = Int32(POSIX_SPAWN_SETSID) | Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)

    private static func addChangeDirectory(_ actions: inout posix_spawn_file_actions_t?, _ cwd: String) throws {
        let result = posix_spawn_file_actions_addchdir_np(&actions, cwd)
        guard result == 0 else { throw SpawnError(code: result) }
    }

    private static func closeInheritedDescriptors(
        _ actions: inout posix_spawn_file_actions_t?, withoutCloseFrom: Bool
    ) {}
    #else
    /// glibc's `POSIX_SPAWN_SETSID` (2.26), which its headers only declare under
    /// `_GNU_SOURCE`.
    private static let newSessionFlags: Int32 = 0x80

    private typealias ChangeDirectory = @convention(c) (
        UnsafeMutablePointer<posix_spawn_file_actions_t>, UnsafePointer<CChar>
    ) -> Int32
    private typealias CloseFrom = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>, Int32) -> Int32

    /// glibc 2.29's `posix_spawn_file_actions_addchdir_np`, looked up at run time so the
    /// library still builds against older headers.
    private static let changeDirectory: ChangeDirectory? = symbol("posix_spawn_file_actions_addchdir_np")
    /// glibc 2.34's `posix_spawn_file_actions_addclosefrom_np`.
    private static let closeFrom: CloseFrom? = symbol("posix_spawn_file_actions_addclosefrom_np")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle = dlopen(nil, RTLD_NOW), let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    private static func addChangeDirectory(_ actions: inout posix_spawn_file_actions_t, _ cwd: String) throws {
        guard let changeDirectory else { throw SpawnError(code: ENOSYS) }
        let result = cwd.withCString { changeDirectory(&actions, $0) }
        guard result == 0 else { throw SpawnError(code: result) }
    }

    /// Nothing but the three standard descriptors reaches the command. Before glibc
    /// 2.34 there is no `closefrom` action, so each descriptor open now is closed by
    /// its own: one closed meanwhile is harmless, as glibc ignores `EBADF` there.
    private static func closeInheritedDescriptors(
        _ actions: inout posix_spawn_file_actions_t, withoutCloseFrom: Bool
    ) {
        if let closeFrom, !withoutCloseFrom {
            _ = closeFrom(&actions, 3)
            return
        }
        let open = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
        for descriptor in open.compactMap(Int32.init) where descriptor > 2 {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
    }
    #endif

    private static func withCStrings<R>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    // MARK: - Running

    /// Begin reading output and waiting for the exit. `onOutput` gets each chunk as it
    /// is read, from either pipe; `onExit` the wait status once the command has exited
    /// and been reaped (`nil` if it was reaped elsewhere).
    ///
    /// - Parameter readerStartsLate: for tests, the slowest reader there can be: it
    ///   starts when the exit needs it to, or else once the exit has been reported.
    func start(
        onOutput: @escaping @Sendable ([UInt8]) -> Void, onExit: @escaping @Sendable (Int32?) -> Void,
        readerStartsLate: Bool = false
    ) {
        let reader = Thread { [self] in readOutput(onOutput) }
        reader.name = "acp.terminal.output"
        lock.withLock { pendingReader = reader }
        if !readerStartsLate { lock.withLock { startPendingReader() } }
        let waiter = Thread { [self] in
            onExit(waitForExit())
            lock.withLock { startPendingReader() }
        }
        waiter.name = "acp.terminal.exit"
        waiter.start()
    }

    /// Start the reader if it has not started yet. Called under the lock.
    private func startPendingReader() {
        pendingReader?.start()
        pendingReader = nil
    }

    /// Stop reading output: the pipes are closed, and whatever still writes to them
    /// gets `EPIPE` — Node's `stdout.destroy()`.
    func stopReading() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            wakeReader()
        }
    }

    /// Wake the reader out of `poll`. Called under the lock, so a reader that has
    /// finished — and closed the pipe — is never written to.
    private func wakeReader() {
        guard !readerFinished else { return }
        var byte: UInt8 = 1
        _ = write(wake.write, &byte, 1)
    }

    /// Send `signal` to the command, unless it has already been reaped — then its pid
    /// may belong to another process. Returns whether the signal was sent.
    @discardableResult
    func send(_ signal: Int32) -> Bool {
        lock.withLock { !reaped && kill(pid, signal) == 0 }
    }

    /// Whether the command has exited and been reaped.
    var hasBeenReaped: Bool { lock.withLock { reaped } }

    private func readOutput(_ onOutput: @Sendable ([UInt8]) -> Void) {
        var open = outputDescriptors
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        /// Take in everything `descriptor` holds now. `false` once it is at its end.
        func drain(_ descriptor: Int32) -> Bool {
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    onOutput(Array(buffer[0..<count]))
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return count < 0 && errno == EAGAIN
                }
            }
        }
        while !open.isEmpty {
            var polled = (open + [wake.read]).map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&polled, nfds_t(polled.count), -1) >= 0 else {
                if errno == EINTR { continue }
                break
            }
            let woken = polled.last!.revents != 0
            // Woken, every pipe is emptied: a drain request wants all of it.
            for entry in polled.dropLast() where entry.revents != 0 || woken {
                guard !drain(entry.fd) else { continue }
                close(entry.fd)
                open.removeAll { $0 == entry.fd }
            }
            guard woken else { continue }
            var byte: UInt8 = 0
            while read(wake.read, &byte, 1) > 0 {}
            let stop: Bool = lock.withLock {
                if drainRequested {
                    drainRequested = false
                    drained.signal()
                }
                return stopped
            }
            if stop { break }
        }
        lock.withLock {
            readerFinished = true
            if drainRequested {
                drainRequested = false
                drained.signal()
            }
        }
        open.forEach { close($0) }
        close(wake.read)
        close(wake.write)
    }

    /// Wait for the exit without reaping (`WNOWAIT`); have the reader take in what the
    /// command left in the pipes; then reap under the lock: until ``reaped`` is set, the
    /// pid is still this command's, running or a zombie.
    private func waitForExit() -> Int32? {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 {
            guard errno == EINTR else { break }
        }
        let draining: Bool = lock.withLock {
            guard !readerFinished, !stopped else { return false }
            drainRequested = true
            startPendingReader()
            wakeReader()
            return true
        }
        if draining { drained.wait() }
        return lock.withLock {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &status, 0)
            } while result < 0 && errno == EINTR
            reaped = true
            return result == pid ? status : nil
        }
    }

    // MARK: - Exit status

    /// Node's `(code, signal)` for a wait status: an exit code, or the name of the
    /// signal that ended the command.
    static func exitStatus(_ status: Int32?) -> TerminalExitStatus {
        guard let status else { return TerminalExitStatus() }
        let signal = status & 0x7F
        if signal == 0 { return TerminalExitStatus(exitCode: Int((status >> 8) & 0xFF)) }
        return TerminalExitStatus(signal: signalNames[signal] ?? "")
    }

    static let signalNames: [Int32: String] = {
        var names: [Int32: String] = [
            SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL", SIGTRAP: "SIGTRAP",
            SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL", SIGUSR1: "SIGUSR1",
            SIGSEGV: "SIGSEGV", SIGUSR2: "SIGUSR2", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM", SIGTERM: "SIGTERM",
            SIGCHLD: "SIGCHLD", SIGCONT: "SIGCONT", SIGSTOP: "SIGSTOP", SIGTSTP: "SIGTSTP", SIGTTIN: "SIGTTIN",
            SIGTTOU: "SIGTTOU", SIGURG: "SIGURG", SIGXCPU: "SIGXCPU", SIGXFSZ: "SIGXFSZ",
            SIGVTALRM: "SIGVTALRM", SIGPROF: "SIGPROF", SIGWINCH: "SIGWINCH", SIGIO: "SIGIO", SIGSYS: "SIGSYS"
        ]
        #if canImport(Darwin)
        names[SIGEMT] = "SIGEMT"
        names[SIGINFO] = "SIGINFO"
        #else
        names[SIGSTKFLT] = "SIGSTKFLT"
        names[SIGPWR] = "SIGPWR"
        #endif
        return names
    }()
}

/// libuv's names for the errors a spawn reports.
private let errnoNames: [Int32: String] = [
    ENOENT: "ENOENT", EACCES: "EACCES", ENOTDIR: "ENOTDIR", EISDIR: "EISDIR", ENOEXEC: "ENOEXEC",
    E2BIG: "E2BIG", EPERM: "EPERM", ENOMEM: "ENOMEM", EAGAIN: "EAGAIN", ELOOP: "ELOOP",
    ENAMETOOLONG: "ENAMETOOLONG", EINVAL: "EINVAL", EMFILE: "EMFILE", ENFILE: "ENFILE",
    ETXTBSY: "ETXTBSY", EIO: "EIO", ENOSYS: "ENOSYS", EFAULT: "EFAULT"
]
#endif
