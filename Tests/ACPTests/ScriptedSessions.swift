@testable import ACPXCore
@testable import ACPXFlows
import Foundation
import SwiftACP

/// A flow's persistent sessions as a test scripts them (``FlowSessionRunner``), in place of
/// acpxd: each session made with its record written to the store, and each turn answered —
/// its prompt, an answer and the prompt's response on the wire, and the record grown by the
/// prompt and the answer, as acpxd's turn grows it. What was made and let go is kept.
final class ScriptedSessions: FlowSessionRunner, @unchecked Sendable {
    /// A session made: its name, where it works, and its record's id.
    struct Made: Equatable {
        let name: String
        let cwd: String
        let recordId: String
    }

    private let lock = NSLock()
    private var madeSessions: [Made] = []
    private var releasedIds: [String] = []
    private var cleanupSteps: [String] = []
    private var turnCount = 0
    /// Whether a session made is written to the store; without it, its first turn finds no
    /// record.
    var writesRecords = true
    /// The turn, counted from 1 over all sessions, that fails once it has answered.
    var failingTurn: Int?
    /// Time the making attempt out, as its timer would at `timeoutMs`, once the session is made.
    var timeOutWhenMade: Double?
    /// What trying the failed releases again at the run's end fails with.
    var failingRetry: Error?

    var made: [Made] { lock.withLock { madeSessions } }
    var released: [String] { lock.withLock { releasedIds } }
    /// Each release in order — `retry` where the failed ones were tried again.
    var cleanup: [String] { lock.withLock { cleanupSteps } }

    func createPersistent(agent: FlowAgent, name: String, control: FlowTurnControl) async throws -> SessionRecord {
        let recordId = lock.withLock {
            madeSessions.append(Made(name: name, cwd: agent.cwd, recordId: "rec-\(madeSessions.count + 1)"))
            return madeSessions[madeSessions.count - 1].recordId
        }
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: recordId, acpSessionId: recordId, agentCommand: agent.agentCommand, cwd: agent.cwd,
            name: name, createdAt: now, lastUsedAt: now)
        record.closed = false
        if writesRecords { try SessionStore.writeRecord(record) }
        if let timeoutMs = timeOutWhenMade { control.attempt.cancel(FlowTimeoutError(timeoutMs: timeoutMs)) }
        return record
    }

    func runPersistent(_ turn: FlowPersistentTurn) async throws {
        let number = lock.withLock {
            turnCount += 1
            return turnCount
        }
        let answer = "answer \(number)"
        let sessionId = turn.recordId
        let chunk = WireJSON.object([
            ("sessionUpdate", .text("agent_message_chunk")),
            ("content", .object([("type", .text("text")), ("text", .text(answer))]))
        ])
        turn.onMessage(true, try WireJSON.parse(
            #"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"\#(sessionId)"}}"#))
        turn.onMessage(false, .object([
            ("jsonrpc", .text("2.0")), ("method", .text("session/update")),
            ("params", .object([("sessionId", .text(sessionId)), ("update", chunk)]))
        ]))
        turn.onMessage(false, try WireJSON.parse(#"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#))
        guard var record = SessionStore.loadRecord(sessionId) else { throw FlowRunError("no record \(sessionId)") }
        ConversationModel.recordPromptSubmission(into: &record, prompt: turn.prompt)
        ConversationModel.recordSessionUpdate(
            into: &record,
            notification: SessionNotification(sessionId: sessionId, update: .agentMessageChunk(.text(answer))))
        try SessionStore.writeRecord(record)
        if number == failingTurn { throw FlowRunError("turn \(number) failed") }
    }

    func releasePersistent(_ recordId: String) async throws {
        lock.withLock {
            releasedIds.append(recordId)
            cleanupSteps.append(recordId)
        }
    }

    func retryFailedReleases() async throws {
        lock.withLock { cleanupSteps.append("retry") }
        if let failingRetry { throw failingRetry }
    }

    func runIsolated(_ turn: FlowTurn) async throws -> String {
        throw FlowRunError("Scripted sessions run no isolated turn")
    }
}
