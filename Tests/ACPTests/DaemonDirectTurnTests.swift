@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A flow's persistent session in acpxd (#202, step 3b): made with its agent held for its
/// first turn, and each turn run direct, as acpx's `sendSessionDirect` runs it — the session
/// taken back as itself or not at all, the agent let go when the turn ends, and the journal
/// the turn's messages without turn records.
extension DaemonToolsTests {
    /// What each line of the session's journal is: a journal record by its type, a message
    /// by its method, `result` or `error` for a response.
    private static func journalKinds(_ id: String) throws -> [String] {
        let text = try String(contentsOf: ACPXPaths.sessionStreamPath(id), encoding: .utf8)
        return text.split(separator: "\n").map { line in
            guard let value = WireJSON(parsing: String(line)) else { return "?" }
            if value.hasMember("schema"), let type = value["type"]?.stringValue { return type }
            if let method = value["method"]?.stringValue { return method }
            return value.hasMember("error") ? "error" : "result"
        }
    }

    /// The mock agent, answering `session/load` as `mode` says.
    private static func mock(load mode: String) throws -> String {
        "/usr/bin/env MOCK_LOAD_SESSION=\(mode) " + (try #require(mockCommand()))
    }

    private func directTurn(_ daemon: ACPXDaemonBackend, _ sessionId: String, _ text: String) async throws {
        _ = try await daemon.runPrompt(sessionId: sessionId, text: text, permissionMode: "approve-all", direct: true)
    }

    /// The first turn takes the agent that made the session: no `initialize`, no
    /// `session/load`, and — as acpx's journal of a direct turn — no turn records. The
    /// agent is let go when the turn ends, and the record says how it ended.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aHeldSessionsFirstDirectTurnTakesTheAgentThatMadeIt() async throws {
        let command = try Self.mock(load: "ok")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
            #expect(try #require(SessionStore.loadRecord(id)).pid != nil)
            #expect(await daemon.sessionStatus(sessionId: id).live)
            try await directTurn(daemon, id, "one")
            let kinds = try Self.journalKinds(id)
            #expect(kinds.first { $0 != "segment" } == "session/prompt", "\(kinds)")
            for kind in ["initialize", "session/new", "session/load", "turn_started", "turn_result"] {
                #expect(!kinds.contains(kind), "\(kind) in \(kinds)")
            }
            let after = try #require(SessionStore.loadRecord(id))
            #expect(after.pid == nil)
            #expect(after.lastAgentDisconnectReason != nil)
            #expect(await !daemon.sessionStatus(sessionId: id).live)
        }
    }

    /// A later turn takes the session back with `session/load`.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aLaterDirectTurnTakesTheSessionBack() async throws {
        let command = try Self.mock(load: "ok")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
            try await directTurn(daemon, id, "one")
            try await directTurn(daemon, id, "two")
            let kinds = try Self.journalKinds(id)
            let second = try #require(kinds.firstIndex(of: "initialize"))
            #expect(kinds[second...].contains("session/load"), "\(kinds)")
            #expect(!kinds.contains("session/new"), "\(kinds)")
            #expect(await !daemon.sessionStatus(sessionId: id).live)
        }
    }

    /// A turn whose session the agent will not take back fails: no new session replaces it,
    /// as a queued turn's reconnect would start.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnIsNotGivenANewSession() async throws {
        let command = try Self.mock(load: "gone")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
            try await directTurn(daemon, id, "one")
            await #expect(throws: (any Error).self) { try await directTurn(daemon, id, "two") }
            let kinds = try Self.journalKinds(id)
            #expect(kinds.contains("session/load"), "\(kinds)")
            #expect(!kinds.contains("session/new"), "\(kinds)")
            #expect(SessionStore.loadRecord(id)?.acpSessionId == id)
        }
    }
}
