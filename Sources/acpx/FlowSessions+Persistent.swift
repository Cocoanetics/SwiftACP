import ACPXCore
import ACPXFlows
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP

// A flow's persistent sessions, as acpx's runner has them (`createSessionWithClient`,
// `sendSessionDirect`), run by acpxd, which alone writes a session's record and journal:
// the session made with its agent kept for the first turn, and each turn run as acpx runs
// it directly — taken back as itself or not at all, its agent let go when it ends, and every
// message of it streamed back for the run's bundle. Split from `FlowSessions.swift`.
extension FlowAgentSessions {
    /// Runs in a test once a persistent turn's daemon is reached and its stop listened for,
    /// just before the turn is sent.
    @TaskLocal static var beforeSending: (@Sendable () -> Void)?
    /// Runs in a test once acpxd has made a persistent session, before its record is read.
    @TaskLocal static var afterCreating: (@Sendable (_ recordId: String) -> Void)?

    /// acpx's `createSessionWithClient` with the flow runner's options: acpxd makes the
    /// session and keeps its agent, answering its requests meanwhile as the flow's turns are
    /// answered. A stop calls it off: the call is dropped, and acpxd stops making a session
    /// nobody waits for.
    func createPersistent(agent: FlowAgent, name: String, control: FlowTurnControl) async throws -> SessionRecord {
        try control.check()
        let creationToken = UUID().uuidString.lowercased()
        let ceiling = try TerminalOutputLimit.ceiling()
        let proxy = try await Self.connect(until: control) { proxy in
            await proxy.setLogNotificationHandler(AgentStderrLog())
        }
        let stopListening = control.onStop { Task { await proxy.disconnect() } }
        defer { stopListening() }
        let recordId: String
        do {
            // The flow's own servers, from `--mcp-config`, as acpx's runner gives its client the
            // invocation's; without, those of the flow's config, read once, with its `auth`,
            // wherever the node works (#219 review).
            recordId = try await ACPXDaemon.Client(proxy: proxy).newSession(
                agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, mcpServers: config.sessionMcpServers,
                agentArgv: agent.agentArgv, sessionOptions: flowSessionOptions, holdAgent: true, fs: flags.fs,
                permissionMode: permissionMode, nonInteractivePermissions: flags.nonInteractivePermissions,
                permissionPolicy: permissionRules, authPolicy: flags.authPolicy, callerConfig: callerConfig,
                verbose: flags.verbose, creationToken: creationToken, environment: ProcessInfo.processInfo.environment,
                terminalOutputCeiling: ceiling ?? 0)
        } catch {
            await proxy.disconnect()
            // No answer came, or a failure did: whatever acpxd makes of it is let go, now or as it
            // is made, as acpx's runner closes a client made after its attempt stopped — the
            // record's id, which the answer would have named, is never learned (#219 review).
            await creations.callOff(token: creationToken, through: DaemonClient.callOffCreation)
            if let reason = control.stopReason { throw reason }
            // acpxd's own error, as acpx's creation throws it: without the MCP client's
            // `Tool call failed: `.
            throw DaemonClient.controlFailure(error)
        }
        await proxy.disconnect()
        Self.afterCreating?(recordId)
        guard let record = SessionStore.loadRecord(recordId) else {
            // A session whose record cannot be read is never the run's: its agent goes (#219 review).
            await creations.callOff(token: creationToken, through: DaemonClient.callOffCreation)
            throw CLIError("Session not found: \(recordId)")
        }
        creations.keep(creationToken, for: recordId)
        return record
    }

    /// Reach acpxd, starting it if need be — however long a cold one takes to come up, the
    /// attempt's stop cuts the wait short and it ends with why, as acpx's signal aborts its
    /// client's start (#219 review).
    static func connect(
        until control: FlowTurnControl, daemonExecutable: String? = nil,
        configure: @escaping @Sendable (MCPServerProxy) async -> Void
    ) async throws -> MCPServerProxy {
        let reaching = Task {
            try await DaemonClient.connect(
                spawnIfNeeded: true, daemonExecutable: daemonExecutable, configure: configure)
        }
        let stopListening = control.onStop { reaching.cancel() }
        defer { stopListening() }
        do {
            return try await reaching.value
        } catch {
            if let reason = control.stopReason { throw reason }
            throw error
        }
    }

    /// acpx's `sendSessionDirect` with the flow runner's options: acpxd runs the turn
    /// directly, streaming every message of it into the turn's capture. Once the attempt
    /// stops the turn, its prompt is cancelled and given 2.5 s, then its agent let go
    /// (acpx's `ownDirectClient`). A turn that fails lets the session's agent go too, as
    /// acpx's closes the client it was given however it ends: one that failed before acpxd
    /// took the kept agent would leave it kept, with no owner to let it go. Only the agent the
    /// session's creation made is let go, never one that took its place since under the same
    /// id — and should acpxd refuse, the run's end tries again (``retryFailedReleases()``,
    /// #219 review).
    func runPersistent(_ turn: FlowPersistentTurn) async throws {
        do {
            try await runDirect(turn)
        } catch {
            await callOffCreation(of: turn.recordId)
            throw error
        }
        // Its first turn took the agent the session was made with.
        _ = creations.take(turn.recordId)
    }

    private func runDirect(_ turn: FlowPersistentTurn) async throws {
        try turn.control.check()
        let content = try turn.prompt.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
        let ceiling = try TerminalOutputLimit.ceiling()
        let stopReason = StopReasonBox()
        let proxy = try await Self.connect(until: turn.control) { proxy in
            await proxy.setLogNotificationHandler(FlowTurnLog(turn, stopReason: stopReason))
        }
        // The turn's name, which the stop's cancel gives: a stop that comes before acpxd has
        // begun the turn calls it off there, however the two cross (#219 review).
        let turnToken = UUID().uuidString.lowercased()
        let stop = FlowDaemonTurnStop(recordId: turn.recordId, turnToken: turnToken)
        let stopListening = turn.control.onStop { stop.stop() }
        defer { stopListening() }
        Self.beforeSending?()
        // Stopped while acpxd was being reached — a cold daemon takes a while — the turn is
        // not sent, as acpx's direct turn checks its signal before it prompts: the stop that
        // just ran found no turn to cancel (#219 review).
        if let reason = turn.control.stopReason {
            await stop.turnEnded()
            await proxy.disconnect()
            throw reason
        }
        do {
            _ = try await DaemonClient.runPrompt(
                on: proxy, stopReason: stopReason, sessionId: turn.recordId, content: content, wait: true,
                permissionMode: permissionMode, nonInteractivePermissions: flags.nonInteractivePermissions,
                permissionPolicy: permissionRules, terminalOutputCeiling: ceiling, mode: PromptTurnMode(
                    streamWire: true, direct: true, fs: flags.fs, authPolicy: flags.authPolicy, turnToken: turnToken,
                    callerConfig: callerConfig, verbose: flags.verbose,
                    environment: ProcessInfo.processInfo.environment))
        } catch {
            await stop.turnEnded()
            await proxy.disconnect()
            if let reason = turn.control.stopReason, stop.stopped { throw reason }
            throw Self.turnError(error)
        }
        await stop.turnEnded()
        await proxy.disconnect()
        // A turn the attempt stopped fails with why, though its prompt ended cancelled.
        if let reason = turn.control.stopReason { throw reason }
    }

    /// Let go of the agent a session was made with, if acpxd still keeps it — never one that
    /// took its place since under the same id — the record as it is (acpx closes the client).
    func releasePersistent(_ recordId: String) async throws {
        if case .refused(let error) = await callOffCreation(of: recordId) { throw error }
    }

    /// Call off once more each creation of the run whose call-off acpxd refused — as its call
    /// failed, say, or its first turn did, or its attempt stopped — the agent it made let go if
    /// acpxd still keeps it (#219 review).
    func retryFailedReleases() async throws {
        if let failure = await creations.callOffRefused(through: DaemonClient.callOffCreation) { throw failure }
    }

    /// Call off the creation that made `recordId`'s session, by its token: acpxd lets go of the
    /// agent it made, if it still keeps it.
    @discardableResult
    private func callOffCreation(of recordId: String) async -> DaemonClient.Release {
        await creations.callOff(recordId, through: DaemonClient.callOffCreation)
    }

    /// The flow's config as acpx's runner gives it every client of the run: its `auth` and MCP
    /// servers, read once, as the run began.
    var callerConfig: CallerConfig { CallerConfig(auth: config.auth, mcpServers: config.mcpServers) }

    /// acpx's flow runner's `sessionOptions`: the model, allowed tools and turns.
    var flowSessionOptions: PromptSessionOptions? {
        guard flags.model != nil || flags.allowedTools != nil || flags.maxTurns != nil else { return nil }
        return PromptSessionOptions(model: flags.model, allowedTools: flags.allowedTools, maxTurns: flags.maxTurns)
    }

    /// The permission mode acpxd takes, for the flow's permissions.
    var permissionMode: String {
        switch permission {
        case .approveAll: return "approve-all"
        case .denyAll: return "deny-all"
        default: return "approve-reads"
        }
    }

    /// How a turn acpxd ran failed, as acpx's direct turn fails: with the message the
    /// failure had.
    static func turnError(_ error: Error) -> Error {
        guard let failed = error as? DaemonTurnFailed else { return error }
        return FlowDaemonTurnError(event: failed.event)
    }
}

/// A persistent turn's failure as acpxd described it (``TurnFailedEvent``): the error acpx's
/// direct turn throws, with the ACP error it came of.
struct FlowDaemonTurnError: Error, LocalizedError, OutputErrorMeta, AcpErrorCarrier {
    let event: TurnFailedEvent
    var errorDescription: String? { event.message }
    var acp: AcpErrorPayload? { event.acp.flatMap(AcpErrorPayload.init) }
    var outputCode: String? { event.outputCode }
    var detailCode: String? { event.detailCode }
    var origin: String? { event.origin }
    var retryable: Bool? { event.retryable }
}

/// acpxd's account of a flow's persistent turn: each message of the turn's wire into the
/// turn's capture, and how the turn ended to the call.
final class FlowTurnLog: MCPServerProxyLogNotificationHandling, @unchecked Sendable {
    private let turn: FlowPersistentTurn
    private let stopReason: StopReasonBox

    init(_ turn: FlowPersistentTurn, stopReason: StopReasonBox) {
        self.turn = turn
        self.stopReason = stopReason
    }

    func mcpServerProxy(_ proxy: MCPServerProxy, didReceiveLog message: LogMessage) async {
        if FlowAgentStderr.write(message) { return }
        if let wire = try? message.data.decoded(WireMessageEvent.self) {
            guard let body = WireJSON(parsing: Data(wire.wireLine.utf8)) else { return }
            turn.onMessage(wire.wireDirection == "outbound", body)
        } else if let failed = try? message.data.decoded(TurnFailedEvent.self) {
            await stopReason.fail(failed)
        } else if let ended = try? message.data.decoded(TurnEndedEvent.self) {
            await stopReason.set(ended)
        }
    }
}

/// A call acpxd runs for this CLI under `--verbose` — the making of a flow's persistent session,
/// a control — as acpxd tells of it: what its agent writes to stderr, and acpx's own lines.
final class AgentStderrLog: MCPServerProxyLogNotificationHandling, Sendable {
    func mcpServerProxy(_ proxy: MCPServerProxy, didReceiveLog message: LogMessage) async {
        _ = FlowAgentStderr.write(message)
    }
}

/// What a flow's agent writes to stderr, as acpxd streams it under `--verbose`
/// (``AgentStderrEvent``): onto the CLI's stderr, where acpx's client, which runs in the
/// flow's process, shows it.
enum FlowAgentStderr {
    /// Whether `message` is a chunk of the agent's stderr, which is then written out.
    static func write(_ message: LogMessage) -> Bool {
        guard let event = try? message.data.decoded(AgentStderrEvent.self) else { return false }
        if let bytes = event.bytes { FileHandle.standardError.write(bytes) }
        return true
    }
}

/// acpx's `ownDirectClient` for a turn acpxd runs: once stopped, the turn's prompt is
/// cancelled, and unless the turn ends within 2.5 s its agent is let go.
final class FlowDaemonTurnStop: @unchecked Sendable {
    private let recordId: String
    private let turnToken: String?
    private let lock = NSLock()
    private var ended = false
    private var didStop = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopping: Task<Void, Never>?

    init(recordId: String, turnToken: String? = nil) {
        self.recordId = recordId
        self.turnToken = turnToken
    }

    var stopped: Bool { lock.withLock { didStop } }

    func stop() {
        lock.withLock { didStop = true }
        let (recordId, turnToken) = (self.recordId, self.turnToken)
        let task = Task {
            let cancel = try? await DaemonClient.cancelSession(sessionId: recordId, turnToken: turnToken)
            let cancelled = cancel?.cancelled
            let settled = try? await withTimeout(milliseconds: FlowTurnOwner.cancelWaitMilliseconds) {
                await self.waitForEnd()
            }
            // Only this turn's agent is put down, while it runs: what the session has once it has
            // ended is another's (#219 review).
            if settled == nil, Self.forcesRelease(cancelled: cancelled) {
                _ = await DaemonClient.releaseSession(sessionId: recordId, turnToken: turnToken)
            }
        }
        lock.withLock { stopping = task }
    }

    /// Whether a turn still going past its grace has its agent put down, given what the cancel
    /// said: yes when the cancel found the turn running, or went unanswered — the release is the
    /// turn's own, and does nothing once it has ended — but not when it found the turn not yet
    /// begun, which ends as it begins (#219 review).
    static func forcesRelease(cancelled: Bool?) -> Bool {
        cancelled != false
    }

    /// The turn is over: a stop under way stops waiting for it, and is done before this returns.
    func turnEnded() async {
        let (waiting, stopping) = lock.withLock {
            ended = true
            defer { waiters = [] }
            return (waiters, self.stopping)
        }
        waiting.forEach { $0.resume() }
        await stopping?.value
    }

    private func waitForEnd() async {
        await withCheckedContinuation { continuation in
            let over = lock.withLock {
                if ended { return true }
                waiters.append(continuation)
                return false
            }
            if over { continuation.resume() }
        }
    }
}

/// The token each persistent session of a flow run was made under, by its record: what lets go
/// of the agent that creation made — and no other that took its place since under the same id,
/// as an agent that gives every session the same id makes happen (#219 review).
final class FlowCreations: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    /// The creations whose call-off the daemon refused, by token, kept for another try.
    private var refused: Set<String> = []

    func keep(_ token: String, for recordId: String) {
        lock.withLock { tokens[recordId] = token }
    }

    /// The token `recordId`'s session was made under, forgotten.
    func take(_ recordId: String) -> String? {
        lock.withLock {
            guard let token = tokens.removeValue(forKey: recordId) else { return nil }
            refused.remove(token)
            return token
        }
    }

    /// Call `recordId`'s creation off through `callOff`, by its token (``callOff(token:through:)``).
    func callOff(
        _ recordId: String, through callOff: (String) async -> DaemonClient.Release
    ) async -> DaemonClient.Release {
        guard let token = lock.withLock({ tokens[recordId] }) else { return .released(false) }
        return await self.callOff(token: token, through: callOff)
    }

    /// Call off the creation made under `token` through `callOff`: kept should the daemon
    /// refuse — a connection dropped, say — so the run's end can try again
    /// (``callOffRefused(through:)``), and forgotten once the call-off is settled, the agent
    /// let go or no daemon holding it (#219 review).
    @discardableResult
    func callOff(token: String, through callOff: (String) async -> DaemonClient.Release) async -> DaemonClient.Release {
        let outcome = await callOff(token)
        lock.withLock {
            if case .refused = outcome {
                refused.insert(token)
            } else {
                refused.remove(token)
                tokens = tokens.filter { $0.value != token }
            }
        }
        return outcome
    }

    /// Call off once more, through `callOff`, each creation whose call-off the daemon refused
    /// — each one tried; the first refusal returned, if another comes (#219 review).
    func callOffRefused(through callOff: (String) async -> DaemonClient.Release) async -> (any Error)? {
        var failure: (any Error)?
        for token in lock.withLock({ refused.sorted() }) {
            if case .refused(let error) = await self.callOff(token: token, through: callOff), failure == nil {
                failure = error
            }
        }
        return failure
    }
}
