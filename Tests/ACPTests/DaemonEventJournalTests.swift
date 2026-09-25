@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A daemon turn is journaled as acpx 0.19.1's queue owner journals it (#89): between its
/// `turn_started` and `turn_result`, keyed by the turn's request id, with the exchange that
/// connected the agent, and each message as `JSON.stringify` prints what the agent wrote.
extension DaemonToolsTests {
    private static let schema = #"{"schema":"acpx.session.journal.v1","type":"#

    /// The session's event log, line by line.
    private static func journal(_ id: String) throws -> [String] {
        try String(contentsOf: ACPXPaths.sessionStreamPath(id), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// What each line of the log is: a journal record by its type, a message by its
    /// method, `result` or `error` for a response.
    private static func kinds(_ lines: [String]) -> [String] {
        lines.map { line in
            guard let value = WireJSON(parsing: line) else { return "?" }
            if value.hasMember("schema"), let type = value["type"]?.stringValue { return type }
            if let method = value["method"]?.stringValue { return method }
            return value.hasMember("error") ? "error" : "result"
        }
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTurnIsJournaledWithTheExchangeThatConnectedIt() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: CallingClient())

            // The agent can't load a session, so connecting starts a new one, as acpx's does.
            let lines = try Self.journal(session.id)
            #expect(Self.kinds(lines) == [
                "segment", "turn_started", "initialize", "result", "session/new", "result",
                "session/prompt", "session/update", "result", "turn_result"
            ])
            // Keyed by the turn's request id — a UUID, as acpx's — which the record keeps.
            let record = try #require(SessionStore.loadRecord(session.id))
            let requestId = try #require(record.lastRequestId)
            let uuid = /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/
            #expect(requestId.wholeMatch(of: uuid) != nil)
            #expect(lines[1] == Self.schema + #""turn_started","request_id":"\#(requestId)"}"#)
            #expect(lines.last == Self.schema
                + #""turn_result","request_id":"\#(requestId)","#
                + #""result":{"status":"completed","stopReason":"end_turn"}}"#)
            // The agent's update in its own key order, which sorting would change.
            #expect(lines[7] == #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"retry-session","#
                + #""update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}"#)
            // `last_seq` counts the messages.
            #expect(record.lastSeq == 7)
            await daemon.releaseAll()
        }
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aFailedTurnIsJournaledWithItsFailure() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("fail-always")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await #expect(throws: (any Error).self) {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: CallingClient())
            }

            let lines = try Self.journal(session.id)
            #expect(Self.kinds(lines).suffix(3) == ["session/prompt", "error", "turn_result"])
            #expect(lines.last?.hasSuffix(#""result":{"status":"failed","error":{"message":"Internal error","#
                + #""code":"RUNTIME","detailCode":"QUEUE_RUNTIME_PROMPT_FAILED"}}}"#) == true)
            await daemon.releaseAll()
        }
    }

    /// The answer's `_meta` goes into the turn's result, as the agent sent it — its key
    /// order kept, its escape as `JSON.stringify` prints it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theAnswersMetaGoesIntoTheTurnsResult() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("meta-answer")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: CallingClient())

            let lines = try Self.journal(session.id)
            #expect(lines.dropLast().last?.hasSuffix(#""result":{"stopReason":"end_turn","_meta":{"z":1,"a":"é"}}}"#)
                == true)
            #expect(lines.last?.hasSuffix(#""result":{"status":"completed","stopReason":"end_turn","#
                + #""_meta":{"z":1,"a":"é"}}}"#) == true)
            await daemon.releaseAll()
        }
    }

    /// A turn whose journal cannot be written fails before it connects, and the session's
    /// agent is let go, as acpx's queue owner retires its client.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTurnWhoseJournalCannotBeWrittenFails() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: CallingClient())
            #expect(await daemon.heldConnection(session.id) != nil)
            let path = ACPXPaths.sessionStreamPath(session.id).path
            #expect(chmod(path, 0o400) == 0)
            defer { chmod(path, 0o600) }

            let client = CallingClient()
            await #expect(throws: SessionJournalWriteError.self) {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: client)
            }
            #expect(client.failure?.detailCode == "SESSION_JOURNAL_WRITE_FAILED")
            #expect(session.prompts == 1)
            #expect(await daemon.heldConnection(session.id) == nil)
            await daemon.releaseAll()
        }
    }

    /// A turn that finds its session's journal corrupt fails before it connects; the agent
    /// held for the session stays, as acpx's owner keeps its client then.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTurnThatFindsItsJournalCorruptFails() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: CallingClient())
            let handle = try FileHandle(forWritingTo: ACPXPaths.sessionStreamPath(session.id))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("not json\n".utf8))
            try handle.close()

            let client = CallingClient()
            let corrupt = SessionJournalError(
                code: "WATCH_JOURNAL_CORRUPT", message: "Invalid complete line in session journal")
            await #expect(throws: corrupt) {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: client)
            }
            #expect(client.failure?.message == "Invalid complete line in session journal")
            #expect(session.prompts == 1)
            #expect(await daemon.heldConnection(session.id) != nil)
            await daemon.releaseAll()
        }
    }
}
