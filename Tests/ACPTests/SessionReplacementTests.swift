@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// When a reconnect has to start a new session, the record moves to it (#56): acpx sets
/// `acpSessionId` to the replacement and keeps `acpxRecordId`, so the next reconnect
/// asks for the session the agent actually has — not the one that was already gone.
extension DaemonToolsTests {
    private static func loadedSessionIds(_ requests: [[String: Any]]) -> [String] {
        requests.filter { $0["method"] as? String == "session/load" }
            .compactMap { ($0["params"] as? [String: Any])?["sessionId"] as? String }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aReplacementBecomesTheRecordsSession() async throws {
        try await withLoggedMockRequests(loadMode: "gone", sessionIdPerProcess: true) { command, requests in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "first")

            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.acpxRecordId == id)
            #expect(record.acpSessionId != id)
            #expect(record.hasAgentMessages)

            // A restarted daemon asks for the replacement, not the original.
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "second")
            #expect(Self.loadedSessionIds(try requests()) == [id, record.acpSessionId])
        }
    }

    /// The same daemon keeps serving the replacement under the record — later turns,
    /// addressed by either id, do not reconnect.
    @Test(.enabled(if: mockPythonAvailable))
    func theReplacementIsHeldUnderTheRecord() async throws {
        try await withLoggedMock(loadMode: "gone", sessionIdPerProcess: true) { command, methods in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            let replacement = try #require(SessionStore.loadRecord(id)).acpSessionId
            let before = try methods().count

            _ = try await daemon.runPrompt(sessionId: replacement, text: "second")
            _ = try await daemon.runPrompt(sessionId: id, text: "third")
            #expect(Array(try methods().dropFirst(before)) == ["session/prompt", "session/prompt"])
        }
    }

    /// Rewrite the stored record, as something before the call under test left it.
    private static func editRecord(_ id: String, _ edit: (inout SessionRecord) -> Void) throws {
        var record = try #require(SessionStore.loadRecord(id))
        edit(&record)
        try SessionStore.writeRecord(record)
    }

    /// A turn takes the replacement onto the record it saves before the saved choices
    /// are replayed: the replay waits on the agent, and a checkpoint of the turn's
    /// record during it would otherwise write the old session back.
    @Test(.enabled(if: mockPythonAvailable))
    func theReplacementIsHandedOverBeforeTheReplay() async throws {
        try await withLoggedMock(loadMode: "gone", sessionIdPerProcess: true) { command, methods in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            // A saved mode, so the replay has something to send.
            try Self.editRecord(id) { record in
                var acpx = record.acpx ?? SessionAcpxState()
                acpx.desiredModeId = "auto"
                record.acpx = acpx
            }
            let record = try #require(SessionStore.loadRecord(id))
            let before = try methods().count
            let (handedOver, handOver) = AsyncStream<String>.makeStream()
            let (resumed, resume) = AsyncStream<Void>.makeStream()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let connecting = Task {
                _ = try await daemon.ensure(
                    recordId: id, agentCommand: record.agentCommand, cwd: record.cwd, mcpServers: nil,
                    onReplacement: { response in
                        handOver.yield(response.sessionId)
                        for await _ in resumed { break }
                    })
            }
            // Held at the hand-over: the agent has started the new session, and has not
            // been asked for anything since.
            let replacement = await handedOver.first { _ in true }
            #expect(replacement != nil && replacement != record.acpSessionId)
            #expect(Array(try methods().dropFirst(before)) == ["session/load", "session/new"])
            resume.yield()
            try await connecting.value
            #expect(Array(try methods().dropFirst(before)) == ["session/load", "session/new", "session/set_mode"])
        }
    }

    /// An agent that gives every session the same id still starts a new one, and what
    /// that one advertised replaces the old state — the turn does not save it back.
    @Test(.enabled(if: mockPythonAvailable))
    func aReplacementUnderTheSameIdStillReplacesTheModelState() async throws {
        try await withLoggedMock(loadMode: "gone") { command, methods in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            try Self.editRecord(id) { record in
                var acpx = record.acpx ?? SessionAcpxState()
                acpx.currentModelId = "gone-model"
                acpx.availableModels = ["gone-model"]
                record.acpx = acpx
            }
            let before = try methods().count
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "hi")

            #expect(Array(try methods().dropFirst(before).prefix(2)) == ["session/load", "session/new"])
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.acpSessionId == id)
            // The new session advertised no models, so none are known any more.
            #expect(record.acpx?.currentModelId == nil)
            #expect(record.acpx?.availableModels == nil)
            #expect(record.hasAgentMessages)
        }
    }

    /// Calls addressed by the ACP session id, queued behind a turn that replaces that
    /// session, still find their record: after the wait they look it up by the record
    /// id they resolved before queueing.
    @Test(.enabled(if: mockPythonAvailable))
    func queuedCallsFollowTheirRecordToTheReplacement() async throws {
        try await withLoggedMock(loadMode: "ok") { command, _ in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            // An earlier fallback moved the record, so callers know it by another id.
            try Self.editRecord(id) { $0.acpSessionId = "replacement-1" }

            let (queued, noteQueued) = AsyncStream<String>.makeStream()
            await daemon.turnQueue.setOnQueued { noteQueued.yield($0) }
            try await daemon.turnQueue.acquire(id, wait: true)
            async let turn = daemon.runPrompt(sessionId: "replacement-1", text: "queued")
            // `restart`: when the turn goes first, it leaves its agent live with other servers.
            async let servers = daemon.setSessionMcpServers(
                sessionId: "replacement-1", mcpServers: [], restart: true)
            // Both wait behind the held slot, while the turn holding it replaces the session.
            _ = await queued.prefix(2).reduce(0) { count, _ in count + 1 }
            try Self.editRecord(id) { $0.acpSessionId = "replacement-2" }
            await daemon.turnQueue.release(id)

            let (reply, stored) = try await (turn, servers)
            #expect(reply.contains("You said: queued"))
            #expect(stored)
            #expect(try #require(SessionStore.loadRecord(id)).acpSessionId == "replacement-2")
        }
    }

    /// A control that connects the session saves the record it changes — with the
    /// replacement, not the identity it had before connecting.
    @Test(.enabled(if: mockPythonAvailable))
    func aControlKeepsTheReplacement() async throws {
        try await withLoggedMock(loadMode: "gone", sessionIdPerProcess: true) { command, _ in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).setMode(sessionId: id, modeId: "auto")
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.acpSessionId != id)
            #expect(record.acpx?.desiredModeId == "auto")
        }
    }
}
