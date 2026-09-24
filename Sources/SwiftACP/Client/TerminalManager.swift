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
///   ``TerminalProcess``), in the request's `cwd` or the manager's. Given no `args`,
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
    private let outputCeiling: Int?
    /// How long `SIGTERM` has before `SIGKILL`.
    public let killGrace: TimeInterval
    private var terminals: [String: ManagedTerminal] = [:]

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
        self.cwd = cwd
        self.outputCeiling = outputCeiling
        self.killGrace = max(0, killGrace)
    }

    // MARK: - ACP methods

    public func createTerminal(_ request: CreateTerminalRequest) async throws -> CreateTerminalResponse {
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

    /// acpx's `spawnTerminalProcess`: the command as given, then — with no `args`, not
    /// found, not an existing path, and shell syntax or whitespace in it — the same
    /// line through `/bin/sh -c`. A failure is Node's `spawn <command> <code>`.
    private static func start(_ request: CreateTerminalRequest, cwd: String) throws -> TerminalProcess {
        let environment = Self.environment(request.env)
        do {
            return try TerminalProcess.spawn(
                command: request.command, arguments: request.args ?? [], cwd: cwd, environment: environment)
        } catch let error as TerminalProcess.SpawnError {
            guard request.args == nil, error.code == ENOENT, runsThroughShell(request.command, cwd: cwd) else {
                throw TerminalError.spawnFailed(command: request.command, code: error.name)
            }
            do {
                return try TerminalProcess.spawn(
                    command: "/bin/sh", arguments: ["-c", request.command], cwd: cwd, environment: environment)
            } catch let error as TerminalProcess.SpawnError {
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
        let status = TerminalProcess.exitStatus(status)
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
        signal(terminal, SIGTERM)
        guard await !cleanedUp(terminal) else { return }
        signal(terminal, SIGKILL)
        _ = await cleanedUp(terminal)
    }

    /// Each process started under the command, from a fresh snapshot, then the command.
    private func signal(_ terminal: ManagedTerminal, _ signal: Int32) {
        terminal.descendants.signal(signal, rootIsRunning: terminal.isRunning)
        if terminal.isRunning { terminal.process.send(signal) }
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
    let process: TerminalProcess
    let output: TerminalOutput
    let descendants: ProcessDescendants
    /// Set as soon as the command has exited.
    var exitStatus: TerminalExitStatus?
    /// Set once the exit has been fully recorded; what `terminal/wait_for_exit` answers.
    var exitResponse: WaitForTerminalExitResponse?
    var exitWaiters: [CheckedContinuation<WaitForTerminalExitResponse, Never>] = []

    init(process: TerminalProcess, output: TerminalOutput) {
        self.process = process
        self.output = output
        self.descendants = ProcessDescendants(root: process.pid)
    }

    var isRunning: Bool { exitStatus == nil }
}
#endif
