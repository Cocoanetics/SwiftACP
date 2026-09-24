#if os(macOS) || os(Linux)
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A child process acpx would start with Node's `spawn`, in one of two ways
/// (``ChildSpawn`` starts it):
///
/// - a terminal's command, as acpx's `spawnAndWait` starts it — `spawn(command, args,
///   {detached: true, stdio: ["ignore", "pipe", "pipe"]})`: in a new session, so it
///   leads its own process group and has no controlling terminal (a command reading
///   `/dev/tty` fails instead of stopping, and nothing it prints reaches the user's
///   terminal), stdin from `/dev/null`;
/// - an agent, as acpx's `spawnAgentProcess` starts it — `spawn(command, args, {stdio:
///   ["pipe", "pipe", "pipe"]})`: in this process's session and group, its stdin on a
///   pipe written with ``write(_:)``.
///
/// Stdout and stderr are each on a pipe, read on a thread of its own until both close
/// (a background child can keep them open after the process exits) or
/// ``stopReading()``. Another thread waits for the process to exit, has the reader take
/// in everything already in the pipes — all it wrote before exiting — and only then
/// reaps it and reports the exit, under the same lock as ``send(_:)``: a signal never
/// reaches a process that reused its pid, and output read after the exit is all there.
final class ChildProcess: @unchecked Sendable {
    /// Why a process could not be started: the errno, named as Node names it.
    typealias SpawnError = ChildSpawn.SpawnError

    /// One of the process's output pipes.
    enum Output: Sendable, Equatable {
        case stdout
        case stderr
    }

    let pid: pid_t
    /// Stdout's and stderr's read ends, in that order.
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
    /// The write end of stdin's pipe, `nil` without one or once closed. Writes hold
    /// ``inputLock`` — not ``lock``, as a write can wait for the child to read.
    private var inputDescriptor: Int32?
    private let inputLock = NSLock()

    private init(pid: pid_t, outputDescriptors: [Int32], wake: (read: Int32, write: Int32), input: Int32?) {
        self.pid = pid
        self.outputDescriptors = outputDescriptors
        self.wake = wake
        self.inputDescriptor = input
    }

    // MARK: - Starting

    /// Start `command` with `arguments` in `cwd`. `environment` is the command's whole
    /// environment, its `PATH` included; `nil` passes this process's own.
    ///
    /// - Parameters:
    ///   - input: give it a stdin pipe to ``write(_:)`` to — an agent's — instead of
    ///     `/dev/null`.
    ///   - newSession: start it in a session of its own, as a terminal's command is.
    ///   - withoutCloseFrom: for tests, close inherited descriptors as on a glibc
    ///     without `closefrom` (Linux; ignored elsewhere).
    ///   - withoutChangeDirectory: for tests, change into `cwd` as on a glibc without the
    ///     `addchdir` spawn action.
    static func spawn(
        command: String, arguments: [String], cwd: String, environment: [String: String]?,
        input: Bool = false, newSession: Bool = true, withoutCloseFrom: Bool = false,
        withoutChangeDirectory: Bool = false
    ) throws -> ChildProcess {
        let variables = environment ?? ProcessInfo.processInfo.environment
        let executable = try ChildSpawn.resolveExecutable(command, cwd: cwd, path: variables["PATH"])
        var opened: [Int32] = []
        func pipe(nonBlockingReadEnd: Bool = true) throws -> (read: Int32, write: Int32) {
            let pipe = try ChildSpawn.makePipe(nonBlockingReadEnd: nonBlockingReadEnd)
            opened += [pipe.read, pipe.write]
            return pipe
        }
        do {
            let stdout = try pipe()
            let stderr = try pipe()
            let wake = try pipe()
            let stdin = input ? try pipe(nonBlockingReadEnd: false) : nil
            let pid = try ChildSpawn.launch(
                executable, argv: [command] + arguments, cwd: cwd,
                environment: variables.map { "\($0.key)=\($0.value)" }, stdin: stdin.map { .pipe($0.read) } ?? .null,
                stdout: stdout.write, stderr: stderr.write, newSession: newSession, withoutCloseFrom: withoutCloseFrom,
                withoutChangeDirectory: withoutChangeDirectory)
            [stdout.write, stderr.write].forEach { close($0) }
            if let stdin {
                close(stdin.read)
                withoutSIGPIPE(stdin.write)
            }
            return ChildProcess(
                pid: pid, outputDescriptors: [stdout.read, stderr.read], wake: wake, input: stdin?.write)
        } catch {
            opened.forEach { close($0) }
            throw error
        }
    }

    /// A write to a pipe the child has closed fails with `EPIPE` rather than raising
    /// `SIGPIPE`, which would end this process. Darwin says so of the descriptor;
    /// elsewhere ``write(_:)`` blocks the signal while it writes.
    private static func withoutSIGPIPE(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        #endif
    }

    // MARK: - Running

    /// Begin reading output and waiting for the exit. `onOutput` gets each chunk as it
    /// is read, from either pipe; `onExit` the wait status once the process has exited
    /// and been reaped (`nil` if it was reaped elsewhere).
    ///
    /// - Parameter readerStartsLate: for tests, the slowest reader there can be: it
    ///   starts when the exit needs it to, or else once the exit has been reported.
    func start(
        onOutput: @escaping @Sendable ([UInt8]) -> Void, onExit: @escaping @Sendable (Int32?) -> Void,
        readerStartsLate: Bool = false
    ) {
        start(onChunk: { _, chunk in onOutput(chunk) }, onExit: onExit, readerStartsLate: readerStartsLate)
    }

    /// ``start(onOutput:onExit:readerStartsLate:)``, telling the pipes apart: `onChunk`
    /// gets each chunk with the pipe it was read from, and `onClose` each pipe that
    /// reached its end — not one ``stopReading()`` closed.
    func start(
        onChunk: @escaping @Sendable (Output, [UInt8]) -> Void,
        onClose: @escaping @Sendable (Output) -> Void = { _ in },
        onExit: @escaping @Sendable (Int32?) -> Void, readerStartsLate: Bool = false
    ) {
        let reader = Thread { [self] in readOutput(onChunk, onClose) }
        reader.name = "acp.child.output"
        lock.withLock { pendingReader = reader }
        if !readerStartsLate { lock.withLock { startPendingReader() } }
        let waiter = Thread { [self] in
            onExit(waitForExit())
            lock.withLock { startPendingReader() }
        }
        waiter.name = "acp.child.exit"
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
        _ = Foundation.write(wake.write, &byte, 1)
    }

    /// Send `signal` to the process, unless it has already been reaped — then its pid
    /// may belong to another process. Returns whether the signal was sent.
    @discardableResult
    func send(_ signal: Int32) -> Bool {
        lock.withLock { !reaped && kill(pid, signal) == 0 }
    }

    /// Whether the process has exited and been reaped.
    var hasBeenReaped: Bool { lock.withLock { reaped } }

    // MARK: - Input

    /// Write all of `bytes` to the process's stdin, waiting while its pipe is full.
    /// Throws ``SpawnError`` with the errno — `EPIPE` once the process closed its end,
    /// `EBADF` after ``closeInput()`` or without a stdin pipe.
    func write(_ bytes: [UInt8]) throws {
        try inputLock.withLock {
            guard let descriptor = inputDescriptor else { throw SpawnError(code: EBADF) }
            try Self.whileSIGPIPEIsBlocked {
                var offset = 0
                while offset < bytes.count {
                    let count = bytes[offset...].withUnsafeBytes {
                        Foundation.write(descriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        offset += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        throw SpawnError(code: count < 0 ? errno : EIO)
                    }
                }
            }
        }
    }

    /// Close the process's stdin, which it reads as its end — Node's `stdin.end()`.
    /// A write under way finishes first.
    func closeInput() {
        inputLock.withLock {
            guard let descriptor = inputDescriptor else { return }
            close(descriptor)
            inputDescriptor = nil
        }
    }

    /// Run `body` with `SIGPIPE` blocked on this thread, taking any it raised before
    /// unblocking it. Darwin's descriptor does not raise it (``withoutSIGPIPE(_:)``).
    private static func whileSIGPIPEIsBlocked(_ body: () throws -> Void) throws {
        #if canImport(Darwin)
        try body()
        #else
        var pipeSignal = sigset_t()
        sigemptyset(&pipeSignal)
        sigaddset(&pipeSignal, SIGPIPE)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &pipeSignal, &previous)
        defer {
            if sigismember(&previous, SIGPIPE) == 0 {
                var pending = sigset_t()
                sigpending(&pending)
                if sigismember(&pending, SIGPIPE) == 1 {
                    var immediately = timespec()
                    _ = sigtimedwait(&pipeSignal, nil, &immediately)
                }
            }
            pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
        try body()
        #endif
    }

    // MARK: - Output

    private func readOutput(_ onChunk: @Sendable (Output, [UInt8]) -> Void, _ onClose: @Sendable (Output) -> Void) {
        var open = outputDescriptors
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        func output(_ descriptor: Int32) -> Output { descriptor == outputDescriptors[0] ? .stdout : .stderr }
        /// Take in up to `limit` bytes of what `descriptor` holds. `false` once it is at
        /// its end.
        func take(_ descriptor: Int32, upTo limit: Int) -> Bool {
            var remaining = limit
            while remaining > 0 {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, min($0.count, remaining)) }
                if count > 0 {
                    onChunk(output(descriptor), Array(buffer[0..<count]))
                    remaining -= count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return count < 0 && errno == EAGAIN
                }
            }
            return true
        }
        func closePipe(_ descriptor: Int32) {
            close(descriptor)
            open.removeAll { $0 == descriptor }
            onClose(output(descriptor))
        }
        while !open.isEmpty {
            var polled = (open + [wake.read]).map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&polled, nfds_t(polled.count), -1) >= 0 else {
                if errno == EINTR { continue }
                break
            }
            // A bounded read per ready pipe, then back to `poll`: a writer that never
            // stops cannot keep the loop from the wake pipe.
            for entry in polled.dropLast() where entry.revents != 0 {
                if !take(entry.fd, upTo: buffer.count) { closePipe(entry.fd) }
            }
            guard polled.last!.revents != 0 else { continue }
            var byte: UInt8 = 0
            while read(wake.read, &byte, 1) > 0 {}
            let (stop, draining) = lock.withLock { (stopped, drainRequested) }
            if draining {
                // What each pipe holds now — all the process wrote before it exited — and
                // no more: a background child may never stop writing.
                for descriptor in open where !take(descriptor, upTo: Self.pendingBytes(descriptor)) {
                    closePipe(descriptor)
                }
                lock.withLock {
                    drainRequested = false
                    drained.signal()
                }
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

    /// How many bytes `descriptor` holds now (`FIONREAD`); a pipe's worth if unknown.
    private static func pendingBytes(_ descriptor: Int32) -> Int {
        var pending: Int32 = 0
        let result = withUnsafeMutablePointer(to: &pending) { ioctl(descriptor, bytesPending, $0) }
        return result == 0 ? Int(pending) : 64 * 1024
    }

    #if canImport(Darwin)
    /// Darwin's `FIONREAD`, `_IOR('f', 127, int)`, which Swift does not import.
    private static let bytesPending: UInt = 0x4004_667F
    #else
    private static let bytesPending = UInt(FIONREAD)
    #endif

    // MARK: - Exit

    /// Wait for the exit without reaping (`WNOWAIT`); have the reader take in what the
    /// process left in the pipes; then reap under the lock: until ``reaped`` is set, the
    /// pid is still this process's, running or a zombie.
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

    /// Node's `(code, signal)` for a wait status — see ``ChildSpawn/exitStatus(_:)``.
    static func exitStatus(_ status: Int32?) -> TerminalExitStatus {
        ChildSpawn.exitStatus(status)
    }
}
#endif
