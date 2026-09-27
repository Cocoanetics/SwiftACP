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
    /// acpx's `createSessionWithClient` with the flow runner's options: acpxd makes the
    /// session and keeps its agent. A stop calls it off: the call is dropped, and acpxd stops
    /// making a session nobody waits for.
    func createPersistent(agent: FlowAgent, name: String, control: FlowTurnControl) async throws -> SessionRecord {
        try control.check()
        let proxy = try await DaemonClient.connect(spawnIfNeeded: true)
        let stopListening = control.onStop { Task { await proxy.disconnect() } }
        defer { stopListening() }
        let recordId: String
        do {
            recordId = try await ACPXDaemon.Client(proxy: proxy).newSession(
                agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, mcpServers: nil,
                agentArgv: agent.agentArgv, sessionOptions: flowSessionOptions, holdAgent: true, fs: flags.fs)
        } catch {
            await proxy.disconnect()
            if let reason = control.stopReason { throw reason }
            // acpxd's own error, as acpx's creation throws it: without the MCP client's
            // `Tool call failed: `.
            throw DaemonClient.controlFailure(error)
        }
        await proxy.disconnect()
        guard let record = SessionStore.loadRecord(recordId) else { throw CLIError("Session not found: \(recordId)") }
        return record
    }

    /// acpx's `sendSessionDirect` with the flow runner's options: acpxd runs the turn
    /// directly, streaming every message of it into the turn's capture. Once the attempt
    /// stops the turn, its prompt is cancelled and given 2.5 s, then its agent let go
    /// (acpx's `ownDirectClient`).
    func runPersistent(_ turn: FlowPersistentTurn) async throws {
        try turn.control.check()
        let stopReason = StopReasonBox()
        let proxy = try await DaemonClient.connect(spawnIfNeeded: true) { proxy in
            await proxy.setLogNotificationHandler(FlowTurnLog(turn, stopReason: stopReason))
        }
        let stop = FlowDaemonTurnStop(recordId: turn.recordId)
        let stopListening = turn.control.onStop { stop.stop() }
        defer { stopListening() }
        let content = try turn.prompt.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
        do {
            _ = try await DaemonClient.runPrompt(
                on: proxy, stopReason: stopReason, sessionId: turn.recordId, content: content, wait: true,
                permissionMode: permissionMode, nonInteractivePermissions: flags.nonInteractivePermissions,
                permissionPolicy: permissionRules, terminalOutputCeiling: try TerminalOutputLimit.ceiling(),
                streamWire: true, direct: true, fs: flags.fs)
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

    /// Let go of a session's kept agent, the record as it is (acpx closes the client).
    func releasePersistent(_ recordId: String) async throws {
        if case .refused(let error) = await DaemonClient.releaseSession(sessionId: recordId) { throw error }
    }

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

/// acpx's `ownDirectClient` for a turn acpxd runs: once stopped, the turn's prompt is
/// cancelled, and unless the turn ends within 2.5 s its agent is let go.
final class FlowDaemonTurnStop: @unchecked Sendable {
    private let recordId: String
    private let lock = NSLock()
    private var ended = false
    private var didStop = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopping: Task<Void, Never>?

    init(recordId: String) {
        self.recordId = recordId
    }

    var stopped: Bool { lock.withLock { didStop } }

    func stop() {
        lock.withLock { didStop = true }
        let recordId = self.recordId
        let task = Task {
            _ = try? await DaemonClient.cancelSession(sessionId: recordId)
            let settled = try? await withTimeout(milliseconds: FlowTurnOwner.cancelWaitMilliseconds) {
                await self.waitForEnd()
            }
            if settled == nil { _ = await DaemonClient.releaseSession(sessionId: recordId) }
        }
        lock.withLock { stopping = task }
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
