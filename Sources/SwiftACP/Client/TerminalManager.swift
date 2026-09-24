#if os(macOS) || os(Linux)
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Runs the commands an agent asks the client for — acpx's `TerminalManager`.
///
/// - `terminal/create` starts the command in its own session and process group (see
///   ``ChildProcess``), in the request's `cwd` or the manager's. Given no `args`,
///   a command that is not found as a program but reads like a shell command line
///   runs through `/bin/sh -c` instead.
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
    public init(
        cwd: String = FileManager.default.currentDirectoryPath, outputCeiling: Int? = nil,
        killGrace: TimeInterval = TerminalManager.defaultKillGrace
    ) {
        self.init(cwd: cwd, outputCeiling: outputCeiling, killGrace: killGrace, signalGap: 0)
    }

    init(cwd: String, outputCeiling: Int? = nil, killGrace: TimeInterval, signalGap: TimeInterval) {
        self.cwd = cwd
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
        let process = try Self.start(request, cwd: request.cwd ?? cwd)
        let terminal = ManagedTerminal(process: process, output: output)
        let terminalId = UUID().uuidString.lowercased()
        terminals[terminalId] = terminal
        process.start(
            onOutput: { output.append($0) },
            onExit: { [weak self] status in
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
        await kill(try terminal(request.terminalId))
        return KillTerminalResponse()
    }

    /// A terminal that is not (or no longer) there is already released: that is not an
    /// error, as it is not for acpx.
    public func releaseTerminal(_ request: ReleaseTerminalRequest) async throws -> ReleaseTerminalResponse {
        guard let terminal = terminals[request.terminalId] else { return ReleaseTerminalResponse() }
        await kill(terminal)
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

    // MARK: - Starting

    /// acpx's `spawnChildProcess`: the command as given, then — with no `args`, not
    /// found, not an existing path, and shell syntax or whitespace in it — the same
    /// line through `/bin/sh -c`. A failure is Node's `spawn <command> <code>`.
    private static func start(_ request: CreateTerminalRequest, cwd: String) throws -> ChildProcess {
        // What Node's `spawn` refuses before starting anything — after the approval, as
        // in acpx, so a command that was asked about is refused rather than cut short.
        try NodeSpawnArguments.validate(command: request.command, args: request.args ?? [], cwd: cwd, env: request.env)
        let environment = Self.environment(request.env)
        do {
            return try ChildProcess.spawn(
                command: request.command, arguments: request.args ?? [], cwd: cwd, environment: environment)
        } catch let error as ChildProcess.SpawnError {
            guard request.args == nil, error.code == ENOENT, runsThroughShell(request.command, cwd: cwd) else {
                throw TerminalError.spawnFailed(command: request.command, code: error.name)
            }
            do {
                return try ChildProcess.spawn(
                    command: "/bin/sh", arguments: ["-c", request.command], cwd: cwd, environment: environment)
            } catch let error as ChildProcess.SpawnError {
                throw TerminalError.spawnFailed(command: "/bin/sh", code: error.name)
            }
        }
    }

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

    /// acpx's `toEnvObject`: the request's variables over this process's environment,
    /// or `nil` — inherit it — when the request names none.
    private static func environment(_ variables: [EnvVariable]?) -> [String: String]? {
        guard let variables, !variables.isEmpty else { return nil }
        var merged = ProcessInfo.processInfo.environment
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
    private func recordExit(of terminalId: String, status: Int32?) {
        guard let terminal = terminals[terminalId] else { return }
        let status = ChildProcess.exitStatus(status)
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
    /// exit, then `SIGKILL` and one more.
    private func kill(_ terminal: ManagedTerminal) async {
        await signal(terminal, SIGTERM)
        guard await !cleanedUp(terminal) else { return }
        await signal(terminal, SIGKILL)
        _ = await cleanedUp(terminal)
    }

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
        while terminal.isRunning || hasLiveDescendants(terminal) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            await Self.pause(min(0.025, remaining))
        }
        return true
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
    /// Set as soon as the command has exited.
    var exitStatus: TerminalExitStatus?
    /// Set once the exit has been fully recorded; what `terminal/wait_for_exit` answers.
    var exitResponse: WaitForTerminalExitResponse?
    var exitWaiters: [CheckedContinuation<WaitForTerminalExitResponse, Never>] = []

    init(process: ChildProcess, output: TerminalOutput) {
        self.process = process
        self.output = output
        self.descendants = ProcessDescendants(root: process.pid)
    }

    var isRunning: Bool { exitStatus == nil }
}
#endif
