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
