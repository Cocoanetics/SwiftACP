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
    /// windowsHide: true, windowsVerbatimArguments })` (``WindowsLaunch``): `nil` where that fails,
    /// as when nothing is found for the command.
    static func start(
        _ spawn: WindowsSpawnCommand, cwd: String, environment: [String: String]?
    ) -> WindowsProbeProcess? {
        var security = WindowsLaunch.inheritable()
        guard let input = WindowsLaunch.openNull(&security) else { return nil }
        defer { CloseHandle(input) }
        guard let output = WindowsLaunch.makePipe(&security) else { return nil }
        defer { CloseHandle(output.write) }
        guard let errors = WindowsLaunch.makePipe(&security) else {
            CloseHandle(output.read)
            return nil
        }
        defer { CloseHandle(errors.write) }
        let launch = try? WindowsLaunch.start(
            spawn, cwd: cwd, environment: environment, stdio: [input, output.write, errors.write])
        guard let launch else {
            CloseHandle(output.read)
            CloseHandle(errors.read)
            return nil
        }
        var exitWaitable: HANDLE?
        let duplicated = DuplicateHandle(
            GetCurrentProcess(), launch.process, GetCurrentProcess(), &exitWaitable, DWORD(SYNCHRONIZE), false, 0)
        guard duplicated, let exitWaitable else {
            if let job = launch.job {
                TerminateJobObject(job, 1)
                CloseHandle(job)
            } else {
                TerminateProcess(launch.process, 1)
            }
            CloseHandle(launch.process)
            CloseHandle(output.read)
            CloseHandle(errors.read)
            return nil
        }
        return WindowsProbeProcess(
            process: launch.process, job: launch.job, stdout: output.read, stderr: errors.read,
            exitWaitable: exitWaitable)
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
