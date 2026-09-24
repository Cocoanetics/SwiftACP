@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// The agent's own session id, which acpx records as `agent_session_id` (#75): read from
/// the `_meta` of the replies that open a session, set when the session is created, and
/// reconciled on every reconnect — a new id replaces the old, none keeps it.
@Suite(.serialized) struct AgentSessionIdTests {
    /// acpx's `extractAgentSessionId`.
    @Test func theIdIsTheMetasAgentSessionIdElseItsSessionId() {
        let extract = { (meta: JSONValue?) in AgentSessionId.extract(from: meta) }
        #expect(extract(.object(["agentSessionId": .string(" agent-xyz ")])) == "agent-xyz")
        #expect(extract(.object(["sessionId": .string("s-1")])) == "s-1")
        #expect(extract(.object(["agentSessionId": .string("a"), "sessionId": .string("s")])) == "a")
        #expect(extract(.object(["agentSessionId": .string("  "), "sessionId": .string("s")])) == "s")
        #expect(extract(.object(["agentSessionId": .integer(5)])) == nil)
        #expect(extract(.string("not an object")) == nil)
        #expect(extract(.array([.string("x")])) == nil)
        #expect(extract(nil) == nil)
    }

    /// acpx's `reconcileAgentSessionId`.
    @Test func aNewIdReplacesTheOldAndNoneKeepsIt() {
        var record = SessionRecord(
            acpxRecordId: "r", acpSessionId: "s", agentCommand: "a", cwd: "/",
            createdAt: "2026-09-24T00:00:00.000Z", lastUsedAt: "2026-09-24T00:00:00.000Z")
        record.reconcileAgentSessionId("first")
        record.reconcileAgentSessionId(nil)
        record.reconcileAgentSessionId(" ")
        #expect(record.agentSessionId == "first")
        record.reconcileAgentSessionId(" second ")
        #expect(record.agentSessionId == "second")
    }

    @Test func aLoadReplyKeepsItsMeta() throws {
        let response = try JSONDecoder().decode(
            LoadSessionResponse.self, from: Data(#"{"_meta":{"sessionId":"agent-after-load"}}"#.utf8))
        #expect(AgentSessionId.extract(from: response.meta) == "agent-after-load")
    }

    private func mock(newMeta: String?, loadMeta: String?, loadMode: String) throws -> String {
        let command = try #require(mockCommand())
        var environment = "MOCK_LOAD_SESSION=\(loadMode) "
        if let newMeta { environment += "MOCK_NEW_META='\(newMeta)' " }
        if let loadMeta { environment += "MOCK_LOAD_META='\(loadMeta)' " }
        return "/usr/bin/env \(environment)\(command)"
    }

    /// Created with the id `session/new` named; a turn's reconnect takes the one its
    /// `session/load` names.
    @Test(.enabled(if: mockPythonAvailable))
    func aReconnectTakesTheIdItsLoadNames() async throws {
        let command = try mock(
            newMeta: #"{"agentSessionId": " agent-xyz "}"#, loadMeta: #"{"sessionId": "agent-after-load"}"#,
            loadMode: "ok")
        try await withIsolatedStore {
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            #expect(SessionStore.loadRecord(id)?.agentSessionId == "agent-xyz")
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "hi")
            #expect(SessionStore.loadRecord(id)?.agentSessionId == "agent-after-load")
        }
    }

    /// A control reconnects without a turn, and writes the id itself.
    @Test(.enabled(if: mockPythonAvailable))
    func aControlsReconnectTakesTheIdToo() async throws {
        let command = try mock(newMeta: nil, loadMeta: #"{"agentSessionId": "after-control"}"#, loadMode: "ok")
        try await withIsolatedStore {
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            #expect(SessionStore.loadRecord(id)?.agentSessionId == nil)
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).setMode(sessionId: id, modeId: "plan")
            #expect(SessionStore.loadRecord(id)?.agentSessionId == "after-control")
        }
    }

    /// A load that names none keeps the recorded id.
    @Test(.enabled(if: mockPythonAvailable))
    func aLoadThatNamesNoneKeepsTheId() async throws {
        let command = try mock(newMeta: #"{"sessionId": "s-from-new"}"#, loadMeta: nil, loadMode: "ok")
        try await withIsolatedStore {
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "hi")
            #expect(SessionStore.loadRecord(id)?.agentSessionId == "s-from-new")
        }
    }

    /// A session the agent no longer has is replaced by a new one, and its id is the
    /// new session's.
    @Test(.enabled(if: mockPythonAvailable))
    func aReplacementTakesItsOwnId() async throws {
        let command = try mock(newMeta: #"{"agentSessionId": "fresh"}"#, loadMeta: nil, loadMode: "gone")
        try await withIsolatedStore {
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            var record = try #require(SessionStore.loadRecord(id))
            record.agentSessionId = "old"
            try SessionStore.writeRecord(record)
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "hi")
            #expect(SessionStore.loadRecord(id)?.agentSessionId == "fresh")
        }
    }
}
