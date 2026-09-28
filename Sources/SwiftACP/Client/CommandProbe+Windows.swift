#if os(Windows)
import Foundation
import WinSDK

/// acpx's command probe (`readAgentCommandOutput`, `captureCommandProbeOutput`) on Windows (#265):
/// `gemini --version` or `copilot --help`, started as acpx and Node start it there
/// (``WindowsSpawnCommand``, ``LibuvSpawn``), in the agent's directory and environment. It runs
/// with `stdin` on `NUL`, no window, and in a job of its own, so ending the job ends everything
/// the probe started.
enum CommandProbe {
    /// What `command` wrote once it exited and both its pipes closed — stdout, a newline, then
    /// stderr, whatever its exit — or `nil` when it could not start, ran past
    /// `timeoutMilliseconds`, or its caller was called off first. Whatever is left of it is ended
    /// then, as acpx's client retires a probe however it went. `retired` hears, once that is done,
    /// how many processes the probe's job held over its life and how many of them still run.
    static func output(
        of command: String, _ arguments: [String], cwd: String, environment: [String: String]?,
        timeoutMilliseconds: Int, retired: (@Sendable (_ held: Int, _ running: Int) -> Void)? = nil
    ) async -> String? {
        let spawn = WindowsSpawnCommand(
            command: command, arguments: arguments, environment: environment ?? ProcessInfo.processInfo.environment,
            cwd: cwd, fileSystem: .local)
        guard let child = WindowsProbeProcess.start(spawn, cwd: cwd, environment: environment) else { return nil }
        let capture = CommandProbeCapture()
        child.watch(
            onChunk: { capture.append($0, $1) }, onClose: { capture.pipeClosed() }, onExit: { capture.exited() })
        let output = await withTaskCancellationHandler {
            await capture.output(within: timeoutMilliseconds)
        } onCancel: {
            capture.giveUp()
        }
        if Task.isCancelled {
            // Its caller has stopped waiting; the probe is ended all the same.
            Task.detached { await retire(child, retired: retired) }
        } else {
            await retire(child, retired: retired)
        }
        return output
    }

    /// Everything the probe started, ended at once: on Windows Node's `kill` terminates, for
    /// acpx's `SIGTERM` as for its `SIGKILL`. Then a second at most for all of it to go, looked
    /// at every 25 ms, as acpx's `waitForCleanupAfterSignal` looks.
    private static func retire(
        _ child: WindowsProbeProcess, retired: (@Sendable (_ held: Int, _ running: Int) -> Void)?
    ) async {
        child.terminate()
        let deadline = DispatchTime.now() + .seconds(1)
        while child.runningProcesses > 0, DispatchTime.now() < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(25)) { continuation.resume() }
            }
        }
        retired?(child.heldProcesses, child.runningProcesses)
        child.close()
    }
}

/// A probe's processes: the one started, in a job with everything it starts.
final class WindowsProbeProcess: @unchecked Sendable {
    /// A handle another thread may hold.
    private struct Handle: @unchecked Sendable {
        let raw: HANDLE
    }

    /// `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, a macro Swift does not import.
    private static let handleListAttribute = DWORD_PTR(0x0002_0002)

    private let process: HANDLE
    /// Closing it ends whatever is still in it (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`).
    private let job: HANDLE?
    private let stdout: Handle
    private let stderr: Handle
    /// A second handle to the process, for the thread that waits for its exit.
    private let exitWaitable: Handle

    private init(process: HANDLE, job: HANDLE?, stdout: HANDLE, stderr: HANDLE, exitWaitable: HANDLE) {
        self.process = process
        self.job = job
        self.stdout = Handle(raw: stdout)
        self.stderr = Handle(raw: stderr)
        self.exitWaitable = Handle(raw: exitWaitable)
    }

    /// libuv's `uv_spawn` for acpx's `spawn(command, args, { stdio: ["ignore", "pipe", "pipe"],
    /// windowsHide: true, windowsVerbatimArguments })`: `nil` where that fails, as when nothing is
    /// found for the command.
    static func start(
        _ spawn: WindowsSpawnCommand, cwd: String, environment: [String: String]?
    ) -> WindowsProbeProcess? {
        let parent = ProcessInfo.processInfo.environment
        let path = environment.flatMap { WindowsSpawnCommand.value(of: "PATH", in: $0) }
            ?? WindowsSpawnCommand.value(of: "PATH", in: parent)
        let searchesCurrentDirectory = "".withCString(encodedAs: UTF16.self) { NeedCurrentDirectoryForExePathW($0) }
        guard let application = LibuvSpawn.searchPath(
            spawn.command, cwd: cwd, path: path, searchesCurrentDirectory: searchesCurrentDirectory,
            isFile: WindowsSpawnCommand.FileSystem.local.isFile)
        else { return nil }
        let commandLine = LibuvSpawn.commandLine([spawn.command] + spawn.arguments, verbatim: spawn.verbatimArguments)
        var block = environment.map { LibuvSpawn.environmentBlock($0, parent: parent) }

        var security = SECURITY_ATTRIBUTES(
            nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
        guard let input = openNull(&security) else { return nil }
        defer { CloseHandle(input) }
        guard let output = makePipe(&security) else { return nil }
        defer { CloseHandle(output.write) }
        guard let errors = makePipe(&security) else {
            CloseHandle(output.read)
            return nil
        }
        defer { CloseHandle(errors.write) }
        let started = create(
            application: application, commandLine: commandLine, environment: &block, cwd: cwd,
            stdio: [input, output.write, errors.write])
        guard let started else {
            CloseHandle(output.read)
            CloseHandle(errors.read)
            return nil
        }
        return running(started, stdout: output.read, stderr: errors.read)
    }

    /// The started process put in a job and let run, with a second handle for its exit.
    private static func running(
        _ started: PROCESS_INFORMATION, stdout: HANDLE, stderr: HANDLE
    ) -> WindowsProbeProcess? {
        guard let process = started.hProcess, let thread = started.hThread else { return nil }
        defer { CloseHandle(thread) }
        let job = makeJob(for: process)
        var exitWaitable: HANDLE?
        let duplicated = DuplicateHandle(
            GetCurrentProcess(), process, GetCurrentProcess(), &exitWaitable, DWORD(SYNCHRONIZE), false, 0)
        guard duplicated, let exitWaitable, ResumeThread(thread) != DWORD.max else {
            if let job {
                TerminateJobObject(job, 1)
                CloseHandle(job)
            } else {
                TerminateProcess(process, 1)
            }
            if let exitWaitable { CloseHandle(exitWaitable) }
            CloseHandle(process)
            CloseHandle(stdout)
            CloseHandle(stderr)
            return nil
        }
        return WindowsProbeProcess(
            process: process, job: job, stdout: stdout, stderr: stderr, exitWaitable: exitWaitable)
    }

    /// `CreateProcessW`, suspended until the process is in its job, inheriting only `stdio`.
    private static func create(
        application: String, commandLine: String, environment: inout [UInt16]?, cwd: String, stdio: [HANDLE]
    ) -> PROCESS_INFORMATION? {
        var size = SIZE_T(0)
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { memory.deallocate() }
        let attributes = LPPROC_THREAD_ATTRIBUTE_LIST(memory)
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &size) else { return nil }
        defer { DeleteProcThreadAttributeList(attributes) }
        // The list must outlive the attribute list, so it is not a temporary buffer.
        let inherited = UnsafeMutablePointer<HANDLE?>.allocate(capacity: stdio.count)
        inherited.initialize(from: stdio.map { Optional($0) }, count: stdio.count)
        defer { inherited.deallocate() }
        guard UpdateProcThreadAttribute(
            attributes, 0, handleListAttribute, inherited, SIZE_T(MemoryLayout<HANDLE?>.stride * stdio.count), nil, nil)
        else { return nil }

        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES) | DWORD(STARTF_USESHOWWINDOW)
        startup.StartupInfo.wShowWindow = WORD(SW_HIDE)
        startup.StartupInfo.hStdInput = stdio[0]
        startup.StartupInfo.hStdOutput = stdio[1]
        startup.StartupInfo.hStdError = stdio[2]
        startup.lpAttributeList = attributes
        // No window, as none of its stdio is the console's (libuv's `windowsHide`).
        let flags = DWORD(CREATE_UNICODE_ENVIRONMENT) | DWORD(EXTENDED_STARTUPINFO_PRESENT)
            | DWORD(CREATE_NO_WINDOW) | DWORD(CREATE_SUSPENDED)
        var information = PROCESS_INFORMATION()
        var line = Array(commandLine.utf16) + [0]
        let created = application.withCString(encodedAs: UTF16.self) { applicationName in
            cwd.withCString(encodedAs: UTF16.self) { directory in
                line.withUnsafeMutableBufferPointer { line in
                    withBlock(&environment) { block in
                        withUnsafeMutablePointer(to: &startup) { startup in
                            CreateProcessW(
                                applicationName, line.baseAddress, nil, nil, true, flags, block, directory,
                                startup.pointer(to: \.StartupInfo), &information)
                        }
                    }
                }
            }
        }
        return created ? information : nil
    }

    private static func withBlock<Result>(
        _ block: inout [UInt16]?, _ body: (UnsafeMutableRawPointer?) -> Result
    ) -> Result {
        guard block != nil else { return body(nil) }
        return block!.withUnsafeMutableBufferPointer { body(UnsafeMutableRawPointer($0.baseAddress)) }
    }

    /// `NUL`, for the probe's `stdin` (libuv's `ignore`).
    private static func openNull(_ security: inout SECURITY_ATTRIBUTES) -> HANDLE? {
        let handle = "NUL".withCString(encodedAs: UTF16.self) {
            CreateFileW(
                $0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &security, DWORD(OPEN_EXISTING),
                0, nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        return handle
    }

    /// A pipe whose write end the probe inherits, and whose read end it does not.
    private static func makePipe(_ security: inout SECURITY_ATTRIBUTES) -> (read: HANDLE, write: HANDLE)? {
        var read: HANDLE?
        var write: HANDLE?
        guard CreatePipe(&read, &write, &security, 0), let read, let write else { return nil }
        SetHandleInformation(read, DWORD(HANDLE_FLAG_INHERIT), 0)
        return (read, write)
    }

    /// A job for the probe, which ends whatever is in it once closed. Without one the probe still
    /// runs, but only it is ended.
    private static func makeJob(for process: HANDLE) -> HANDLE? {
        guard let job = CreateJobObjectW(nil, nil) else { return nil }
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        let limited = SetInformationJobObject(
            job, JobObjectExtendedLimitInformation, &limits,
            DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))
        guard limited, AssignProcessToJobObject(job, process) else {
            CloseHandle(job)
            return nil
        }
        return job
    }

    // MARK: - Running

    /// Each pipe read on a thread of its own to its end, and the exit waited for on another.
    func watch(
        onChunk: @escaping @Sendable (CommandProbeCapture.Stream, [UInt8]) -> Void,
        onClose: @escaping @Sendable () -> Void, onExit: @escaping @Sendable () -> Void
    ) {
        Self.read(stdout, as: .stdout, onChunk: onChunk, onClose: onClose)
        Self.read(stderr, as: .stderr, onChunk: onChunk, onClose: onClose)
        let waitable = exitWaitable
        Thread.detachNewThread {
            WaitForSingleObject(waitable.raw, INFINITE)
            CloseHandle(waitable.raw)
            onExit()
        }
    }

    private static func read(
        _ pipe: Handle, as stream: CommandProbeCapture.Stream,
        onChunk: @escaping @Sendable (CommandProbeCapture.Stream, [UInt8]) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                var count: DWORD = 0
                let read = buffer.withUnsafeMutableBytes {
                    ReadFile(pipe.raw, $0.baseAddress, DWORD($0.count), &count, nil)
                }
                // It fails once every write end is closed (`ERROR_BROKEN_PIPE`).
                guard read else { break }
                if count > 0 { onChunk(stream, Array(buffer[..<Int(count)])) }
            }
            CloseHandle(pipe.raw)
            onClose()
        }
    }

    /// Everything in the job ended, or the process alone without one.
    func terminate() {
        if let job { TerminateJobObject(job, 1) } else { TerminateProcess(process, 1) }
    }

    /// How many of the probe's processes still run.
    var runningProcesses: Int {
        guard let job else { return WaitForSingleObject(process, 0) == WAIT_TIMEOUT ? 1 : 0 }
        return Int(Self.accounting(of: job)?.ActiveProcesses ?? 0)
    }

    /// How many processes the probe's job has held over its life: the probe and all it started.
    /// Without a job, only the probe is known.
    var heldProcesses: Int {
        guard let job else { return 1 }
        return Int(Self.accounting(of: job)?.TotalProcesses ?? 0)
    }

    private static func accounting(of job: HANDLE) -> JOBOBJECT_BASIC_ACCOUNTING_INFORMATION? {
        var accounting = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION()
        let queried = QueryInformationJobObject(
            job, JobObjectBasicAccountingInformation, &accounting,
            DWORD(MemoryLayout<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>.size), nil)
        return queried ? accounting : nil
    }

    /// The job and the process let go of; closing the job ends anything still in it.
    func close() {
        if let job { CloseHandle(job) }
        CloseHandle(process)
    }
}
#endif
