#if os(macOS) || os(Linux)
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Starting a child process the way libuv's `uv_spawn` starts one for Node: found on
/// the `PATH` of the environment it is given, as libuv searches it, with every signal
/// at its default disposition and none blocked, whatever this process ignores (Swift
/// programs commonly ignore `SIGPIPE`), and nothing but its three standard descriptors
/// inherited. A terminal's command and an agent are both started here (see
/// ``ChildProcess``).
enum ChildSpawn {
    /// Why a child could not be started: the errno, named as Node names it.
    struct SpawnError: Error, Equatable {
        let code: Int32
        var name: String { errnoNames[code] ?? "UNKNOWN" }
    }

    /// Where a child's standard input comes from.
    enum Input {
        /// `/dev/null`: Node's `"ignore"`.
        case null
        /// The read end of a pipe the parent writes to: Node's `"pipe"`.
        case pipe(Int32)
    }

    /// Where `command` runs from: as given when it names a path (a relative one is
    /// resolved against `cwd` when the command starts), else found on `path` (libuv's
    /// `/usr/bin:/bin` without one) the way libuv searches it, after musl's `execvp`.
    /// A match that cannot run — a directory, a FIFO, a file without the execute bit —
    /// is `EACCES`, and the search goes on past it as past `ENOENT` and `ENOTDIR`; any
    /// other failure ends it. Nothing found is `EACCES` if one was seen, else the last
    /// entry's failure. A name longer than `NAME_MAX` is `ENAMETOOLONG` at once.
    ///
    /// A relative `PATH` entry is looked for from `cwd` — the child's directory — and
    /// returned as it is, since the child resolves it after changing into `cwd`, as
    /// libuv's spawn does.
    static func resolveExecutable(_ command: String, cwd: String, path: String?) throws -> String {
        guard !command.isEmpty else { throw SpawnError(code: ENOENT) }
        if command.contains("/") { return command }
        guard command.utf8.count <= Int(NAME_MAX) else { throw SpawnError(code: ENAMETOOLONG) }
        var sawEACCES = false
        var failure = ENOENT
        for directory in (path ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? "." : String(directory)
            let candidate = "\(base)/\(command)"
            failure = executability(of: base.hasPrefix("/") ? candidate : "\(cwd)/\(candidate)")
            switch failure {
            case 0: return candidate
            case EACCES: sawEACCES = true
            case ENOENT, ENOTDIR: continue
            default: throw SpawnError(code: failure)
            }
        }
        throw SpawnError(code: sawEACCES ? EACCES : failure)
    }

    /// What `execve` would make of `path`, short of running it: `0` for a regular file
    /// this process may execute, `EACCES` for anything else found there, else why
    /// nothing is found.
    private static func executability(of path: String) -> Int32 {
        var status = stat()
        guard stat(path, &status) == 0 else { return errno }
        guard UInt32(status.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG), access(path, X_OK) == 0 else {
            return EACCES
        }
        return 0
    }

    /// A pipe whose ends close on `exec`. `nonBlockingReadEnd` makes the read end —
    /// this process's, when the child writes — non-blocking, for reading with `poll`;
    /// a pipe the child reads from keeps both ends blocking.
    static func makePipe(nonBlockingReadEnd: Bool = true) throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw SpawnError(code: errno) }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        if nonBlockingReadEnd {
            _ = fcntl(descriptors[0], F_SETFL, fcntl(descriptors[0], F_GETFL) | O_NONBLOCK)
        }
        return (descriptors[0], descriptors[1])
    }

    /// Start `executable` (already resolved) with `argv`, in `cwd`, with exactly
    /// `environment`. `stdout` and `stderr` are the write ends of the child's pipes.
    ///
    /// - Parameters:
    ///   - newSession: start it in a session of its own — Node's `detached: true` — so it
    ///     leads its own process group and has no controlling terminal.
    ///   - withoutCloseFrom: for tests, close inherited descriptors as on a glibc
    ///     without `closefrom` (Linux; ignored elsewhere).
    static func launch(
        _ executable: String, argv: [String], cwd: String, environment: [String],
        stdin: Input, stdout: Int32, stderr: Int32, newSession: Bool, withoutCloseFrom: Bool = false
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

        switch stdin {
        case .null: posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        case .pipe(let descriptor): posix_spawn_file_actions_adddup2(&actions, descriptor, 0)
        }
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
        var flags = Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF) | closeOnExecDefault
        if newSession { flags |= newSessionFlag }
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
    /// Node's `detached: true` is `setsid()` in the child; Darwin does it at spawn.
    private static let newSessionFlag = Int32(POSIX_SPAWN_SETSID)
    /// Darwin closes every descriptor the file actions did not set up.
    private static let closeOnExecDefault = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)

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
    private static let newSessionFlag: Int32 = 0x80
    /// Inherited descriptors are closed by file actions instead
    /// (``closeInheritedDescriptors(_:withoutCloseFrom:)``).
    private static let closeOnExecDefault: Int32 = 0

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

    /// Nothing but the three standard descriptors reaches the child. Before glibc 2.34
    /// there is no `closefrom` action, so each descriptor open now is closed by its
    /// own: one closed meanwhile is harmless, as glibc ignores `EBADF` there.
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

    // MARK: - Exit status

    /// Node's `(code, signal)` for a wait status: an exit code, or the name of the
    /// signal that ended the child.
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
