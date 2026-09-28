#if os(macOS) || os(Linux) || os(Windows)
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

/// Runs the commands an agent asks the client for — acpx's `TerminalManager`.
///
/// - `terminal/create` starts the command in its own session and process group (see
///   ``ChildProcess``), in the request's `cwd` or the manager's. Given no `args`,
///   a command that is not found as a program but reads like a shell command line
///   runs through `/bin/sh -c` instead: on Windows, `cmd.exe /d /s /c`, and a `.cmd`
///   or `.bat` through Node's own shell, as acpx starts them there (#272).
/// - Output from stdout and stderr is kept together up to the request's
///   `outputByteLimit` (64 KiB by default) and the host ceiling, dropping the oldest
///   bytes and never splitting a character; `truncated` says bytes were dropped.
/// - `terminal/wait_for_exit` answers once the command has exited, even while a
///   background child keeps its output open.
/// - `terminal/kill` sends `SIGTERM` to the command and everything it started, waits
///   up to ``killGrace`` for all of them to exit, then sends `SIGKILL`. The terminal
///   stays readable. `terminal/release` does the same and forgets the terminal.
/// - ``shutdown()`` releases every terminal, as acpx does when its client closes.
///
/// Whether a command may run is not decided here; see ``TerminalApproval``.
public actor TerminalManager: ACPTerminalHandler {
    /// acpx's `DEFAULT_KILL_GRACE_MS`.
    public static let defaultKillGrace: TimeInterval = 1.5

    private let cwd: String
    /// The environment a command starts over: the client's own — acpx's client spawns its
    /// commands in its process — or `nil`, this process's (#222).
    private let environment: [String: String]?
    private(set) var outputCeiling: Int?
    /// How long `SIGTERM` has before `SIGKILL`.
    public let killGrace: TimeInterval
    /// A pause between signalling the command and what it started: none, but where a
    /// test widens the moment to show the order matters.
    private let signalGap: TimeInterval
    private var terminals: [String: ManagedTerminal] = [:]
    /// Set when ``shutdown()`` begins: no command starts after it.
    private var shutDown = false

    /// - Parameters:
    ///   - cwd: where a command runs when its request names no `cwd`.
    ///   - outputCeiling: the host's cap on every terminal's retained output, whatever
    ///     the request asks for — see ``TerminalOutputLimit/ceiling(environment:)``.
    ///     `nil` is none.
    ///   - killGrace: how long a killed command has to exit before `SIGKILL`.
    ///   - environment: the environment a command starts over, the request's variables laid
    ///     over it: its client's, when that is not this process — `nil`, this process's.
    public init(
        cwd: String = FileManager.default.currentDirectoryPath, outputCeiling: Int? = nil,
        killGrace: TimeInterval = TerminalManager.defaultKillGrace, environment: [String: String]? = nil
    ) {
        self.init(cwd: cwd, outputCeiling: outputCeiling, killGrace: killGrace, signalGap: 0, environment: environment)
    }

    init(
        cwd: String, outputCeiling: Int? = nil, killGrace: TimeInterval, signalGap: TimeInterval,
        environment: [String: String]? = nil
    ) {
        self.cwd = cwd
        self.environment = environment
        self.outputCeiling = outputCeiling
        self.killGrace = max(0, killGrace)
        self.signalGap = signalGap
    }

    /// Caps the output of the terminals created from now on — `nil` is no cap. A
    /// terminal already running keeps the limit it was created with, which acpx
    /// settles once, at `terminal/create`.
    ///
    /// For a host that serves many callers, each with its own ceiling: acpx reads
    /// `ACPX_TERMINAL_MAX_OUTPUT_BYTES` in the process its caller started.
    public func setOutputCeiling(_ ceiling: Int?) {
        outputCeiling = ceiling
    }

    // MARK: - ACP methods

    public func createTerminal(_ request: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        // Nothing below suspends until the terminal is registered, so a shutdown either
        // finds it or has already begun and refuses it here.
        guard !shutDown else { throw CancellationError() }
        let output = TerminalOutput(
            limit: TerminalOutputLimit.resolve(requested: request.outputByteLimit, ceiling: outputCeiling))
        let (process, killsTree) = try Self.start(request, cwd: request.cwd ?? cwd, over: environment)
        let terminal = ManagedTerminal(process: process, output: output, killsTree: killsTree)
        let terminalId = UUID().uuidString.lowercased()
        terminals[terminalId] = terminal
        process.start(
            onChunk: { _, chunk in output.append(chunk) },
            onExitStatus: { [weak self] status in
                Task { await self?.recordExit(of: terminalId, status: status) }
            })
        terminal.descendants.capture(rootIsRunning: terminal.isRunning)
        return CreateTerminalResponse(terminalId: terminalId)
    }

    public func terminalOutput(_ request: TerminalOutputRequest) async throws -> TerminalOutputResponse {
        let terminal = try self.terminal(request.terminalId)
        let (text, truncated) = terminal.output.read()
        return TerminalOutputResponse(output: text, truncated: truncated, exitStatus: terminal.exitStatus)
    }

    public func waitForTerminalExit(_ request: WaitForTerminalExitRequest) async throws
        -> WaitForTerminalExitResponse {
        await exit(of: try terminal(request.terminalId))
    }

    public func killTerminal(_ request: KillTerminalRequest) async throws -> KillTerminalResponse {
        try await kill(try terminal(request.terminalId))
        return KillTerminalResponse()
    }

    /// A terminal that is not (or no longer) there is already released: that is not an
    /// error, as it is not for acpx.
    public func releaseTerminal(_ request: ReleaseTerminalRequest) async throws -> ReleaseTerminalResponse {
        guard let terminal = terminals[request.terminalId] else { return ReleaseTerminalResponse() }
        try await kill(terminal)
        _ = await exit(of: terminal)
        terminal.descendants.retire()
        terminal.process.stopReading()
        terminal.output.clear()
        terminals[request.terminalId] = nil
        return ReleaseTerminalResponse()
    }

    public func shutdown() async {
        shutDown = true
        await withTaskGroup(of: Void.self) { group in
            for terminalId in terminals.keys {
                group.addTask {
                    _ = try? await self.releaseTerminal(
                        ReleaseTerminalRequest(sessionId: "shutdown", terminalId: terminalId))
                }
            }
        }
    }

    /// The process ids of the commands still running: for a test to see them end.
    var runningProcessIds: [Int32] {
        terminals.values.filter(\.isRunning).map(\.process.pid)
    }

    // MARK: - Starting

    #if os(Windows)
    /// acpx's `spawnTerminalProcess` on Windows: the command as acpx starts a terminal's there
    /// (``WindowsSpawnCommand/terminal(command:arguments:environment:cwd:fileSystem:shell:)``), then,
    /// with no `args` and not found, the line through `cmd.exe /d /s /c` if it reads as one
    /// (``WindowsSpawnCommand/terminalFallback(_:cwd:fileSystem:processDirectory:)``), its tree
    /// ended with `taskkill`. That shell is not detached, as acpx's has not been since
    /// openclaw/acpx#797: a detached cmd.exe gives each program it starts a console of its own, and
    /// the program's output goes there. A failure is Node's `spawn <file> <code>`, the file it ran.
    private static func start(
        _ request: CreateTerminalRequest, cwd: String, over base: [String: String]?
    ) throws -> (process: ChildProcess, killsTree: Bool) {
        try NodeSpawnArguments.validate(command: request.command, args: request.args ?? [], cwd: cwd, env: request.env)
        let environment = Self.environment(request.env, over: base)
        // What acpx's process has in `process.env`: the client's.
        let parent = base ?? ProcessInfo.processInfo.environment
        let lookup = WindowsSpawnCommand.lookupEnvironment(
            (request.env ?? []).map { (name: $0.name, value: $0.value) }, over: parent)
        let direct = WindowsSpawnCommand.terminal(
            command: request.command, arguments: request.args ?? [], environment: lookup, cwd: cwd,
            fileSystem: .local, shell: WindowsSpawnCommand.value(of: "COMSPEC", in: parent))
        do {
            let process = try ChildProcess.spawn(direct, cwd: cwd, environment: environment)
            return (process, false)
        } catch let error as ChildProcess.SpawnError {
            guard request.args == nil, error.code == ENOENT,
                  let line = WindowsSpawnCommand.terminalFallback(request.command, cwd: cwd, fileSystem: .local)
            else { throw TerminalError.spawnFailed(command: direct.command, code: error.name) }
            do {
                let process = try ChildProcess.spawn(line, cwd: cwd, environment: environment)
                return (process, true)
            } catch let error as ChildProcess.SpawnError {
                throw TerminalError.spawnFailed(command: line.command, code: error.name)
            }
        }
    }
    #else
    /// acpx's `spawnChildProcess`: the command as given, then — with no `args`, not
    /// found, not an existing path, and shell syntax or whitespace in it — the same
    /// line through `/bin/sh -c`. A failure is Node's `spawn <command> <code>`.
    private static func start(
        _ request: CreateTerminalRequest, cwd: String, over base: [String: String]?
    ) throws -> (process: ChildProcess, killsTree: Bool) {
        // What Node's `spawn` refuses before starting anything — after the approval, as
        // in acpx, so a command that was asked about is refused rather than cut short.
        try NodeSpawnArguments.validate(command: request.command, args: request.args ?? [], cwd: cwd, env: request.env)
        let environment = Self.environment(request.env, over: base)
        do {
            let process = try ChildProcess.spawn(
                command: request.command, arguments: request.args ?? [], cwd: cwd, environment: environment)
            return (process, false)
        } catch let error as ChildProcess.SpawnError {
            guard request.args == nil, error.code == ENOENT, runsThroughShell(request.command, cwd: cwd) else {
                throw TerminalError.spawnFailed(command: request.command, code: error.name)
            }
            do {
                let process = try ChildProcess.spawn(
                    command: "/bin/sh", arguments: ["-c", request.command], cwd: cwd, environment: environment)
                return (process, false)
            } catch let error as ChildProcess.SpawnError {
                throw TerminalError.spawnFailed(command: "/bin/sh", code: error.name)
            }
        }
    }
    #endif

    /// acpx's `buildTerminalFallbackSpawnCommand` on POSIX.
    static func runsThroughShell(_ command: String, cwd: String) -> Bool {
        if command.contains("/") {
            let path = command.hasPrefix("/") ? command : (cwd as NSString).appendingPathComponent(command)
            if FileManager.default.fileExists(atPath: path) { return false }
        }
        return command.unicodeScalars.contains {
            shellSyntax.contains($0) || TerminalOutputLimit.isJavaScriptWhitespace($0)
        }
    }

    /// acpx's `hasShellSyntax`: `[|&;<>()$\`*?[\]{}'"\\\r\n]`.
    private static let shellSyntax = Set("|&;<>()$`*?[]{}'\"\\\r\n".unicodeScalars)

    /// acpx's `toEnvObject`: the request's variables over the client's environment — `base`,
    /// else this process's — and when the request names none, the client's as it is (`nil`:
    /// this process's, inherited).
    private static func environment(_ variables: [EnvVariable]?, over base: [String: String]?) -> [String: String]? {
        guard let variables, !variables.isEmpty else { return base }
        var merged = base ?? ProcessInfo.processInfo.environment
        for variable in variables {
            merged[variable.name] = variable.value
        }
        return merged
    }

    // MARK: - Exit

    private func terminal(_ terminalId: String) throws -> ManagedTerminal {
        guard let terminal = terminals[terminalId] else { throw TerminalError.unknownTerminal(terminalId) }
        return terminal
    }

    /// The command has exited: its status is readable at once, and waiters are answered
    /// once the process group has been looked at one last time, for anything the
    /// command started just before it went.
    private func recordExit(of terminalId: String, status: TerminalExitStatus) {
        guard let terminal = terminals[terminalId] else { return }
        terminal.exitStatus = status
        terminal.descendants.rootExited()
        terminal.descendants.capture(rootIsRunning: false)
        let response = WaitForTerminalExitResponse(status)
        terminal.exitResponse = response
        let waiters = terminal.exitWaiters
        terminal.exitWaiters = []
        for waiter in waiters {
            waiter.resume(returning: response)
        }
    }

    private func exit(of terminal: ManagedTerminal) async -> WaitForTerminalExitResponse {
        if let response = terminal.exitResponse { return response }
        return await withCheckedContinuation { terminal.exitWaiters.append($0) }
    }

    // MARK: - Killing

    /// acpx's `killProcess`: `SIGTERM` to everything, a grace period for all of it to
    /// exit, then `SIGKILL` and one more. On Windows, what still runs after that fails the kill,
    /// as acpx's `waitForFinalCleanup` does there.
    private func kill(_ terminal: ManagedTerminal) async throws {
        #if os(Windows)
        if terminal.killsTree {
            try await killTree(terminal)
            return
        }
        #endif
        await signal(terminal, ProcessSignal.terminate)
        guard await !cleanedUp(terminal) else { return }
        await signal(terminal, ProcessSignal.kill)
        let cleaned = await cleanedUp(terminal)
        #if os(Windows)
        guard cleaned else { throw TerminalError.cleanupUnfinished }
        #else
        _ = cleaned
        #endif
    }

    #if os(Windows)
    /// acpx's kill of a Windows shell launch (`signalWindowsProcessGroup`): `taskkill /t` without
    /// `/f`, which a console program outlasts; the grace; then `taskkill /t /f` whether or not it
    /// went, as acpx cannot see what the shell started.
    private func killTree(_ terminal: ManagedTerminal) async throws {
        await taskkill(terminal, force: false)
        _ = await cleanedUp(terminal)
        await taskkill(terminal, force: true)
        guard await cleanedUp(terminal) else { throw TerminalError.cleanupUnfinished }
    }

    /// acpx's `killWindowsProcessTree`: `taskkill /pid <pid> /t`, `/f` when `force`. It is run on
    /// the shell while it runs, and once the shell is gone on each process it left, as acpx does on
    /// each descendant it saw. As acpx's `execFile`, it runs in this process's directory, where it
    /// is looked for first. Each run is bounded by acpx's `PROCESS_HELPER_TIMEOUT_MS`, and a
    /// failure is ignored.
    private func taskkill(_ terminal: ManagedTerminal, force: Bool) async {
        let pids = terminal.isRunning
            ? [terminal.process.pid]
            : (terminal.process.jobProcessIds() ?? []).map { Int32(bitPattern: $0) }
        for pid in pids {
            let arguments = ["/pid", String(pid), "/t"] + (force ? ["/f"] : [])
            guard let killer = try? ChildProcess.spawn(
                command: "taskkill", arguments: arguments, cwd: FileManager.default.currentDirectoryPath,
                environment: nil)
            else { continue }
            let first = FirstSignal()
            await withCheckedContinuation { continuation in
                killer.start(onChunk: { _, _ in }, onExitStatus: { _ in
                    if first.claim() { continuation.resume() }
                })
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                    if first.claim() { continuation.resume() }
                }
            }
        }
    }
    #endif

    /// The command, then each process started under it, from a snapshot taken while
    /// the command still runs. acpx signals the command last, which leaves a moment
    /// in which a shell can outlive the child it waits for and carry on with its
    /// script — run its next command, or exit `137` before its own `SIGKILL` arrives.
    private func signal(_ terminal: ManagedTerminal, _ signal: Int32) async {
        let tracked = terminal.descendants.capture(rootIsRunning: terminal.isRunning)
        if terminal.isRunning { terminal.process.send(signal) }
        if signalGap > 0 { await Self.pause(signalGap) }
        if tracked { terminal.descendants.signalTracked(signal) }
    }

    /// Whether the command and everything it started exited within ``killGrace``.
    /// There is no event for a process that is not our child exiting, so this looks
    /// every 25 ms, as acpx's `waitForCleanupAfterSignal` does.
    private func cleanedUp(_ terminal: ManagedTerminal) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: killGrace)
        while true {
            // A condition list, not `||`: Swift 6.2 takes the operator's autoclosure for a
            // closure that sends `terminal` across the pause below, and refuses to compile it.
            if !terminal.isRunning, !hasLiveDescendants(terminal) { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            await Self.pause(min(0.025, remaining))
        }
    }

    private func hasLiveDescendants(_ terminal: ManagedTerminal) -> Bool {
        terminal.descendants.capture(rootIsRunning: terminal.isRunning)
        return terminal.descendants.hasTrackedProcesses
    }

    /// A pause that a cancelled task still takes: the kill has to finish either way.
    private static func pause(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}

/// One terminal's state, touched only on its ``TerminalManager``.
private final class ManagedTerminal {
    let process: ChildProcess
    let output: TerminalOutput
    let descendants: ProcessDescendants
    /// A Windows shell launch, whose tree `taskkill` ends: acpx's `killProcessGroup` there.
    let killsTree: Bool
    /// Set as soon as the command has exited.
    var exitStatus: TerminalExitStatus?
    /// Set once the exit has been fully recorded; what `terminal/wait_for_exit` answers.
    var exitResponse: WaitForTerminalExitResponse?
    var exitWaiters: [CheckedContinuation<WaitForTerminalExitResponse, Never>] = []

    init(process: ChildProcess, output: TerminalOutput, killsTree: Bool) {
        self.process = process
        self.output = output
        self.killsTree = killsTree
        #if os(Windows)
        self.descendants = ProcessDescendants(process: process)
        #else
        self.descendants = ProcessDescendants(root: process.pid)
        #endif
    }

    var isRunning: Bool { exitStatus == nil }
}

#if os(Windows)
/// True for its first caller only: whichever of a helper's exit and its time limit comes first.
private final class FirstSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
#endif
#endif
