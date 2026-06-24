import Foundation
import SwiftACP
import Testing

/// Whether `python3` is available for the bundled mock-agent fixture.
let mockPythonAvailable = AgentRegistry.which("python3") != nil

/// Drives a full ACP turn against the bundled `mock-agent.py` over a real
/// subprocess + stdio transport — the complete client stack, hermetically.
struct MockAgentIntegrationTests {
    /// Thread-safe recorder for the streamed updates.
    final class UpdateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var updates: [SessionUpdate] = []
        func record(_ update: SessionUpdate) {
            lock.lock()
            updates.append(update)
            lock.unlock()
        }
        var kinds: [String] {
            lock.lock()
            defer { lock.unlock() }
            return updates.map(\.kind)
        }
    }

    private func mockOverride() -> [String: String]? {
        guard let python = AgentRegistry.which("python3") else { return nil }
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mock-agent.py")
        guard FileManager.default.fileExists(atPath: fixtures.path) else { return nil }
        return ["mock": "'\(python)' '\(fixtures.path)'"]
    }

    @Test(.enabled(if: mockPythonAvailable))
    func fullTurnStreamsAndStops() async throws {
        let overrides = try #require(mockOverride())
        let agent = try await ACPAgent.launch(
            agent: "mock", cwd: NSTemporaryDirectory(), permission: .approveAll,
            inheritStderr: false, overrides: overrides)

        #expect(agent.initializeResult.agentInfo?.name == "mock-agent")

        let session = try await agent.newSession()
        #expect(session.id == "mock-session-1")

        let recorder = UpdateRecorder()
        let outcome = try await session.run("ping") { recorder.record($0) }

        #expect(outcome.stopReason == .endTurn)
        #expect(outcome.text.contains("Hello from the mock agent! You said: ping"))

        let kinds = recorder.kinds
        #expect(kinds.contains("plan"))
        #expect(kinds.contains("tool_call"))
        #expect(kinds.contains("tool_call_update"))
        #expect(kinds.contains("agent_message_chunk"))

        await agent.close()
    }

    @Test(.enabled(if: mockPythonAvailable))
    func twoSequentialTurnsReuseSession() async throws {
        let overrides = try #require(mockOverride())
        let agent = try await ACPAgent.launch(
            agent: "mock", cwd: NSTemporaryDirectory(), permission: .approveAll,
            inheritStderr: false, overrides: overrides)
        let session = try await agent.newSession()

        let first = try await session.run("one")
        let second = try await session.run("two")

        #expect(first.text.contains("one"))
        #expect(second.text.contains("two"))
        #expect(second.stopReason == .endTurn)

        await agent.close()
    }
}
