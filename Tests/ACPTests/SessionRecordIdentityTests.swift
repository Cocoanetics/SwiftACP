@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A session's record has an id of its own, whatever id the agent gives the session, as acpx
/// 0.19.4 gives every new record one (openclaw/acpx#840, for our openclaw/acpx#825): an agent
/// that gives every session the same id — the mock's default — gets a record for each, and two
/// runs on it keep their own conversations. acpx's `session-record-identity.test.ts`.
extension DaemonToolsTests {
    /// Two sessions whose agent gives both one id get two records, each with its own name.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func sessionsOnOneAgentIdGetRecordsOfTheirOwn() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let first = try await Self.created(command, name: "flow-a")
            let second = try await Self.created(command, name: "flow-b")
            #expect(first.acpSessionId == second.acpSessionId)
            #expect(first.acpxRecordId != second.acpxRecordId)
            #expect(first.acpxRecordId != first.acpSessionId)
            #expect(SessionStore.loadRecord(first.acpxRecordId)?.name == "flow-a")
            #expect(SessionStore.loadRecord(second.acpxRecordId)?.name == "flow-b")
        }
    }

    /// Two agents taking back one ACP session at once get a record each, under ids of their
    /// own — acpx's `concurrent native resumes create independent local records`.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func concurrentResumesOfOneSessionGetRecordsOfTheirOwn() async throws {
        let command = try #require(mockCommand())
        let agentA = "/usr/bin/env MOCK_LOAD_SESSION=ok \(command)"
        let agentB = "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_AGENT=b \(command)"
        try await withIsolatedStore {
            async let first = Self.created(agentA, name: "first", resuming: "shared-native-id")
            async let second = Self.created(agentB, name: "second", resuming: "shared-native-id")
            let (recordA, recordB) = try await (first, second)
            #expect(recordA.acpxRecordId != recordB.acpxRecordId)
            #expect(recordA.acpSessionId == "shared-native-id" && recordB.acpSessionId == "shared-native-id")
            #expect(SessionStore.loadRecord(recordA.acpxRecordId)?.name == "first")
            #expect(SessionStore.loadRecord(recordB.acpxRecordId)?.name == "second")
        }
    }

    /// Two sessions acpxd makes on an agent that gives both one id keep their own
    /// conversations: a prompt to one is recorded on it alone — acpx's `flow runs retain
    /// separate histories when adapter session IDs repeat`.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func sessionsOnOneAgentIdKeepTheirOwnConversations() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try await Self.withDaemon { daemon in
                let a = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
                let b = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
                #expect(a != b)
                _ = try await daemon.runPrompt(sessionId: a, text: "from-A-first")
                _ = try await daemon.runPrompt(sessionId: b, text: "from-B-only")
                _ = try await daemon.runPrompt(sessionId: a, text: "from-A-last")
                let (first, second) = (try Self.prompts(a), try Self.prompts(b))
                #expect(first == ["from-A-first", "from-A-last"])
                #expect(second == ["from-B-only"])
                #expect(SessionStore.loadRecord(a)?.acpSessionId == SessionStore.loadRecord(b)?.acpSessionId)
            }
        }
    }

    /// A session created on `command`, its record written: a new one, or `resuming` an ACP
    /// session.
    private static func created(
        _ command: String, name: String, resuming: String? = nil
    ) async throws -> SessionRecord {
        try await SessionEngine.createSession(
            agentCommand: command, cwd: NSTemporaryDirectory(), name: name, permission: .approveAll,
            authCredentials: [:], authPolicy: "skip", resumeSessionId: resuming)
    }

    /// The prompts the session's history has, in order.
    private static func prompts(_ sessionId: String) throws -> [String] {
        let record = try #require(SessionStore.loadRecord(sessionId))
        return record.messages.flatMap { message -> [String] in
            guard case .user(let user) = message else { return [] }
            return user.content.compactMap { if case .text(let text) = $0 { text } else { nil } }
        }
    }
}
