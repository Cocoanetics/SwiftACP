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

    /// The client refuses prompt content the agent never advertised, rather than
    /// letting it be silently ignored — ACP gates image, audio and embedded resource
    /// blocks on `promptCapabilities`, and an agent handed one it did not claim is
    /// free to drop it and answer anyway, which reads as a reply to a question it
    /// never saw. The fixture advertises none of the three.
    @Test(.enabled(if: mockPythonAvailable))
    func unadvertisedPromptContentIsRefusedBeforeDispatch() async throws {
        let overrides = try #require(mockOverride())
        let agent = try await ACPAgent.launch(
            agent: "mock", cwd: NSTemporaryDirectory(), permission: .approveAll,
            inheritStderr: false, overrides: overrides)
        defer { Task { await agent.close() } }
        let session = try await agent.newSession()

        let gated: [(ContentBlock, String)] = [
            (.image(ImageContent(data: "aGk=", mimeType: "image/png")), "image"),
            (.audio(AudioContent(data: "aGk=", mimeType: "audio/wav")), "audio"),
            (.resource(EmbeddedResource(resource: ResourceContents(uri: "file:///a", text: "hi"))),
             "embeddedContext")
        ]
        for (block, capability) in gated {
            let error = await #expect(throws: UnsupportedPromptContentError.self) {
                try await session.prompt([.text("look"), block])
            }
            #expect(error?.index == 1, "\(capability)")
            #expect(error?.capability == capability)
            #expect(error?.agent == "mock-agent")
        }

        // Text and resource_link are never gated, so an ordinary turn still runs.
        let outcome = try await session.run([
            .text("hello"),
            .resourceLink(ResourceLink(uri: "file:///tmp/a.txt", name: "a.txt"))
        ])
        #expect(outcome.stopReason == .endTurn)
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

    // MARK: - Permission refusals through the spawn client

    /// Thread-safe log of what a turn's callbacks saw, in call order.
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        private var operations: [ClientOperation] = []
        func update(_ update: SessionUpdate) {
            lock.lock()
            entries.append("update:\(update.kind)")
            lock.unlock()
        }
        func operation(_ operation: ClientOperation) {
            lock.lock()
            entries.append("operation")
            operations.append(operation)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
        var reported: [ClientOperation] {
            lock.lock()
            defer { lock.unlock() }
            return operations
        }
    }

    /// Launch the mock posing as the Codex adapter (so the connection's Codex
    /// compatibility rules apply) under a deny-all policy. A `refuse:<ids>` prompt
    /// makes it request permission offering `allow` plus those `reject_once` ids,
    /// then report the answer it received as text.
    private func launchAsCodex() async throws -> ACPAgent {
        let overrides = try #require(mockOverride())
        var environment = ProcessInfo.processInfo.environment
        environment["MOCK_AGENT_NAME"] = CodexCompat.agentName
        return try await ACPAgent.launch(
            agent: "mock", cwd: NSTemporaryDirectory(), permission: .denyAll,
            environment: environment, inheritStderr: false, overrides: overrides)
    }

    @Test(.enabled(if: mockPythonAvailable))
    func runKeepsTheTrailingClosureOnUpdatesAndCollectsNotices() async throws {
        let agent = try await launchAsCodex()
        #expect(agent.initializeResult.agentInfo?.name == CodexCompat.agentName)
        let session = try await agent.newSession()

        // The unlabeled trailing closure must stay bound to `onUpdate` in every
        // language mode (see the overload note on `run`), and a refusal that may end
        // the turn is still reported on the outcome without a live callback.
        let log = EventLog()
        let outcome = try await session.run("refuse:cancel") { log.update($0) }
        #expect(log.all.contains("update:agent_message_chunk"))
        #expect(outcome.stopReason == .endTurn)
        #expect(outcome.text.hasPrefix("selected:cancel|notice:"))
        #expect(outcome.clientOperations.count == 1)
        #expect(outcome.clientOperations.first?.method == ClientOperation.requestPermission)
        #expect(outcome.clientOperations.first?.summary.contains("can end the current turn") == true)

        await agent.close()
    }

    @Test(.enabled(if: mockPythonAvailable))
    func runWithBothCallbacksPrefersDeclineAndReportsAbortiveRefusalsLive() async throws {
        let agent = try await launchAsCodex()
        let session = try await agent.newSession()

        // Both refusals offered, `cancel` listed first: the ranking picks `decline`,
        // the turn continues, and there is nothing to explain.
        let declined = EventLog()
        let declinedOutcome = try await session.run(
            "refuse:cancel,decline", onUpdate: { declined.update($0) },
            onClientOperation: { declined.operation($0) })
        #expect(declinedOutcome.text == "selected:decline")
        #expect(declined.reported.isEmpty)
        #expect(declinedOutcome.clientOperations.isEmpty)

        // Only `cancel` offered: the safe refusal is kept and explained live — and
        // in order, ahead of the agent's reaction to the answer.
        let cancelled = EventLog()
        let cancelledOutcome = try await session.run(
            "refuse:cancel", onUpdate: { cancelled.update($0) },
            onClientOperation: { cancelled.operation($0) })
        #expect(cancelledOutcome.text.hasPrefix("selected:cancel|notice:"))
        #expect(cancelled.reported.count == 1)
        #expect(cancelledOutcome.clientOperations == cancelled.reported)
        let order = cancelled.all
        let operationAt = try #require(order.firstIndex(of: "operation"))
        let reactionAt = try #require(order.firstIndex(of: "update:agent_message_chunk"))
        #expect(operationAt < reactionAt)

        await agent.close()
    }
}
