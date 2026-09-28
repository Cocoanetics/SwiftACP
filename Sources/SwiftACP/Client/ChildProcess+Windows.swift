#if os(Windows)
import Foundation
import ucrt
import WinSDK

/// A child process acpx would start with Node's `spawn` on Windows (#272): an agent, as
/// `spawnAgentProcess` starts it there, `spawn(command, args, {stdio: ["pipe", "pipe", "pipe"],
/// windowsHide: true})`, a `.cmd` shim through `cmd.exe` (``WindowsSpawnCommand``,
/// ``WindowsLaunch``). It has the surface ``AgentProcessTransport`` uses of the macOS and Linux one.
///
/// Stdout and stderr are overlapped named pipes, read on one thread that also waits for the
/// process. Once the process has exited, the thread reads what the pipes hold, all it wrote
/// before exiting, and only then reports the exit, as the POSIX one does. Reading goes on until
/// both pipes close (a background child can keep them open) or ``stopReading()``.
package final class ChildProcess: @unchecked Sendable {
    /// Why a process could not be started, or written to: an errno, named as Node names it.
    package struct SpawnError: Error, Equatable, Sendable {
        package let code: Int32
    }

    /// One of the process's output pipes.
    package enum Output: Sendable, Equatable {
        case stdout
        case stderr
    }

    package let pid: Int32
    private let process: HANDLE
    /// The process's job: everything it started (``ProcessDescendants``).
    private let job: HANDLE?
    /// Stdout's and stderr's read ends, overlapped, in that order, and the events their reads set.
    private let outputs: [HANDLE]
    private let outputEvents: [HANDLE]
    /// Set by ``stopReading()``, which wakes the reader.
    private let wake: HANDLE
    private let lock = NSLock()
    private var reaped = false
    private var stopped = false
    /// The signal ``send(_:)`` ended the process with, which its exit reports, as libuv's does.
    private var signalled: Int32?
    /// The write end of stdin's pipe, `nil` without one or once closed. Writes hold ``inputLock``.
    private var input: HANDLE?
    private let inputLock = NSLock()
    /// Whether the reader has the output pipes, which it closes; until it does, they are this one's.
    private var started = false

    private init(launch: WindowsLaunch, outputs: [HANDLE], events: [HANDLE], wake: HANDLE, input: HANDLE?) {
        process = launch.process
        job = launch.job
        pid = Int32(truncatingIfNeeded: GetProcessId(launch.process))
        self.outputs = outputs
        outputEvents = events
        self.wake = wake
        self.input = input
    }

    deinit {
        // What still runs of the process goes with its job, as libuv's children go with Node.
        if let job { CloseHandle(job) }
        CloseHandle(process)
        CloseHandle(wake)
        if let input { CloseHandle(input) }
        if !started { (outputs + outputEvents).forEach { CloseHandle($0) } }
    }

    // MARK: - Starting

    /// Start `command` with `arguments` in `cwd`, as acpx starts it on Windows. `environment` is the
    /// command's whole environment; `nil` passes this process's own.
    ///
    /// - Parameters:
    ///   - input: give it a stdin pipe to ``write(_:)`` to, an agent's, instead of `NUL`.
    ///   - newSession: taken for the POSIX one's sake; a Windows process has none.
    package static func spawn(
        command: String, arguments: [String], cwd: String, environment: [String: String]?,
        input: Bool = false, newSession: Bool = true
    ) throws -> ChildProcess {
        // Node refuses a string with a NUL (`ERR_INVALID_ARG_VALUE`), and so does this.
        let variables = environment ?? ProcessInfo.processInfo.environment
        let strings = [command, cwd] + arguments + variables.flatMap { [$0.key, $0.value] }
        guard !strings.contains(where: { $0.contains("\0") }) else { throw SpawnError(code: EINVAL) }
        let spawn = WindowsSpawnCommand(
            command: command, arguments: arguments, environment: variables, cwd: cwd, fileSystem: .local)
        var security = WindowsLaunch.inheritable()
        var opened: [HANDLE] = []
        func kept(_ handle: HANDLE) -> HANDLE {
            opened.append(handle)
            return handle
        }
        do {
            // Stdin: a pipe to write to, or `NUL`; the child's end first.
            let stdin: (child: HANDLE, ours: HANDLE?)
            if input {
                guard let pipe = WindowsLaunch.makePipe(&security, childReads: true) else {
                    throw SpawnError(code: EMFILE)
                }
                stdin = (kept(pipe.read), kept(pipe.write))
            } else {
                guard let null = WindowsLaunch.openNull(&security) else { throw SpawnError(code: EMFILE) }
                stdin = (kept(null), nil)
            }
            guard let stdout = overlappedPipe(&security).map({ (kept($0.read), kept($0.write)) }),
                  let stderr = overlappedPipe(&security).map({ (kept($0.read), kept($0.write)) }),
                  let stdoutEvent = CreateEventW(nil, true, false, nil).map(kept),
                  let stderrEvent = CreateEventW(nil, true, false, nil).map(kept),
                  let wake = CreateEventW(nil, true, false, nil).map(kept)
            else { throw SpawnError(code: EMFILE) }
            let launch: WindowsLaunch
            do {
                launch = try WindowsLaunch.start(
                    spawn, cwd: cwd, environment: environment, stdio: [stdin.child, stdout.1, stderr.1])
            } catch let failure as WindowsLaunch.Failure {
                throw SpawnError(code: failure.code)
            }
            // The child's ends are the child's now.
            [stdin.child, stdout.1, stderr.1].forEach { CloseHandle($0) }
            return ChildProcess(
                launch: launch, outputs: [stdout.0, stderr.0], events: [stdoutEvent, stderrEvent], wake: wake,
                input: stdin.ours)
        } catch {
            opened.forEach { CloseHandle($0) }
            throw error
        }
    }

    /// A named pipe for one of the process's outputs: its read end overlapped and kept here, its
    /// write end blocking and inherited, as libuv makes one.
    private static func overlappedPipe(_ security: inout SECURITY_ATTRIBUTES) -> (read: HANDLE, write: HANDLE)? {
        let name = "\\\\.\\pipe\\LOCAL\\swiftacp-\(GetCurrentProcessId())-\(UUID().uuidString)"
        let read = name.withCString(encodedAs: UTF16.self) {
            CreateNamedPipeW(
                $0, DWORD(PIPE_ACCESS_INBOUND) | DWORD(FILE_FLAG_OVERLAPPED) | DWORD(FILE_FLAG_FIRST_PIPE_INSTANCE),
                DWORD(PIPE_TYPE_BYTE) | DWORD(PIPE_READMODE_BYTE) | DWORD(PIPE_WAIT)
                    | DWORD(PIPE_REJECT_REMOTE_CLIENTS),
                1, 64 * 1024, 64 * 1024, 0, nil)
        }
        guard let read, read != INVALID_HANDLE_VALUE else { return nil }
        let write = name.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), 0, &security, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let write, write != INVALID_HANDLE_VALUE else {
            CloseHandle(read)
            return nil
        }
        return (read, write)
    }

    // MARK: - Running

    /// Begin reading output and waiting for the exit: `onChunk` gets each chunk with the pipe it
    /// was read from, `onClose` each pipe that reached its end (not one ``stopReading()`` closed),
    /// and `onExitStatus` the exit, as Node reports it, once what the process left in the pipes
    /// has been read.
    ///
    /// - Parameter beforeReaping: for tests, called once the process has exited and what it left
    ///   in the pipes has been read, before the exit is reported.
    package func start(
        onChunk: @escaping @Sendable (Output, [UInt8]) -> Void,
        onClose: @escaping @Sendable (Output) -> Void = { _ in },
        onExitStatus: @escaping @Sendable (TerminalExitStatus) -> Void, beforeReaping: (@Sendable () -> Void)? = nil
    ) {
        lock.withLock { started = true }
        let thread = Thread { [self] in
            let reader = WindowsPipeReader(
                outputs: outputs, events: outputEvents, process: process, wake: wake, onChunk: onChunk,
                onClose: onClose, isStopped: { [self] in lock.withLock { stopped } })
            let exited = reader.run()
            if !exited { WaitForSingleObject(process, INFINITE) }
            beforeReaping?()
            let status = exitStatus()
            lock.withLock { reaped = true }
            onExitStatus(status)
            if exited { reader.finish() }
            reader.release()
        }
        thread.name = "acp.child.io"
        thread.start()
    }

    /// Stop reading output: the pipes are closed, and whatever still writes to them fails, as
    /// Node's `stdout.destroy()` has it.
    package func stopReading() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            SetEvent(wake)
        }
    }

    /// End the process, unless it has been reaped. Node's `kill` on Windows terminates it for any
    /// signal, and libuv reports the exit with that signal. Returns whether it was ended.
    @discardableResult
    package func send(_ signal: Int32) -> Bool {
        lock.withLock {
            guard !reaped, TerminateProcess(process, 1) else { return false }
            signalled = signal
            return true
        }
    }

    /// Whether the process has exited and its exit been reported.
    package var hasBeenReaped: Bool { lock.withLock { reaped } }

    /// Whether the process has exited, its exit reported or not.
    var isExiting: Bool {
        lock.withLock { reaped } || WaitForSingleObject(process, 0) == WindowsPipeReader.signalled
    }

    /// How the process ended, as Node reports it: the signal it was ended with, or its exit code.
    private func exitStatus() -> TerminalExitStatus {
        if let signal = lock.withLock({ signalled }) { return TerminalExitStatus(signal: ProcessSignal.name(signal)) }
        var code: DWORD = 0
        guard GetExitCodeProcess(process, &code) else { return TerminalExitStatus() }
        return TerminalExitStatus(exitCode: Int(code))
    }

    // MARK: - Descendants

    /// The ids of the processes of its job still running, the process's own included.
    func jobProcessIds() -> [DWORD] {
        guard let job else { return [] }
        let capacity = 4096
        let header = MemoryLayout<JOBOBJECT_BASIC_PROCESS_ID_LIST>.offset(of: \.ProcessIdList) ?? 8
        let size = header + MemoryLayout<ULONG_PTR>.stride * capacity
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<ULONG_PTR>.alignment)
        defer { memory.deallocate() }
        guard QueryInformationJobObject(job, JobObjectBasicProcessIdList, memory, DWORD(size), nil) else { return [] }
        let list = memory.assumingMemoryBound(to: JOBOBJECT_BASIC_PROCESS_ID_LIST.self).pointee
        let count = Int(list.NumberOfProcessIdsInList)
        let ids = memory.advanced(by: header).assumingMemoryBound(to: ULONG_PTR.self)
        return (0..<min(count, capacity)).map { DWORD(truncatingIfNeeded: ids[$0]) }
    }

    /// End each process of its job but the process itself.
    func terminateDescendants() {
        let own = DWORD(bitPattern: pid)
        for id in jobProcessIds() where id != own {
            guard let descendant = OpenProcess(DWORD(PROCESS_TERMINATE), false, id) else { continue }
            TerminateProcess(descendant, 1)
            CloseHandle(descendant)
        }
    }

    // MARK: - Input

    /// Write all of `bytes` to the process's stdin, waiting while its pipe is full. Throws
    /// ``SpawnError``: `EPIPE` once the process closed its end, `EBADF` after ``closeInput()``
    /// or without a stdin pipe.
    package func write(_ bytes: [UInt8]) throws {
        try inputLock.withLock {
            guard let input else { throw SpawnError(code: EBADF) }
            var offset = 0
            while offset < bytes.count {
                var written: DWORD = 0
                let wrote = bytes[offset...].withUnsafeBytes {
                    WriteFile(input, $0.baseAddress, DWORD($0.count), &written, nil)
                }
                guard wrote else {
                    let error = GetLastError()
                    let closed = error == DWORD(ERROR_NO_DATA) || error == DWORD(ERROR_BROKEN_PIPE)
                    throw SpawnError(code: closed ? EPIPE : EIO)
                }
                offset += Int(written)
            }
        }
    }

    /// Close the process's stdin, which it reads as its end, as Node's `stdin.end()` does. A write
    /// under way finishes first.
    package func closeInput() {
        inputLock.withLock {
            guard let input else { return }
            CloseHandle(input)
            self.input = nil
        }
    }
}

#endif
