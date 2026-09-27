@testable import ACPXCore
@testable import ACPXFlows
@testable import acpx
import Foundation
@testable import SwiftACP
import Testing

/// The CLI's turn for a flow's ACP node (``FlowAgentSessions``) with a real agent,
/// `retry-agent.py`: every update its connection has read is the turn's, however the turn
/// ends — the agent is closed only once they are handled, as acpx's client takes in all it
/// has read before it closes.
@Suite(.enabled(if: mockPythonAvailable)) struct FlowAgentSessionsTests {
    /// The agent answers, then sends an update. Its handling is held until something waits
    /// for it: here the end of the turn, before it closes the agent.
    @Test(.timeLimit(.minutes(1)))
    func anUpdateReadAsTheTurnEndsIsTheTurns() async throws {
        let taken = try await turnWithALateUpdate { _ in }
        #expect(taken == ["late "])
    }

    /// The same, with the turn stopped — at its deadline — while the update is held: the
    /// stop closes the agent once the update is handled.
    @Test(.timeLimit(.minutes(1)))
    func anUpdateReadAsTheTurnIsStoppedIsTheTurns() async throws {
        let taken = try await turnWithALateUpdate { attempt in
            attempt.cancel(FlowTimeoutError(timeoutMs: 10))
        }
        #expect(taken == ["late "])
    }

    /// Run a turn with the agent in `answer-then-update`. The prompt's answer is held
    /// until the update after it is being handled, then `atTheUpdate` runs; the update is
    /// held until something waits for it. Returns the text of each update the turn took in.
    private func turnWithALateUpdate(
        _ atTheUpdate: @escaping @Sendable (FlowAttempt) -> Void
    ) async throws -> [String] {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-agent.py")
        let agent = FlowAgent(
            agentName: "retry", agentCommand: "/usr/bin/env RETRY_AGENT_MODE=answer-then-update "
                + "'\(python)' '\(fixture.path)'", agentArgv: nil, cwd: NSTemporaryDirectory())
        return try await withIsolatedStore {
            let config = try ConfigLoader.load(cwd: NSTemporaryDirectory())
            let flags = try Flags.resolveGlobalFlags(ScannedArgs(), config: config)
            let attempt = FlowAttempt(nodeId: "ask", attemptId: "ask-1", startedAt: nowISO(), timeoutMs: nil)
            let handling = Gate()
            let (released, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            var sessions = FlowAgentSessions(
                flags: flags, config: config, permission: .approveAll, permissionRules: nil, mcpServers: [])
            sessions.onConnected = { connection in
                await connection.setBeforeHandlingUpdate {
                    handling.open()
                    for await _ in released { break }
                }
                await connection.setOnUpdateWait { _ in release.finish() }
                await connection.setAfterPromptAnswer {
                    await handling.wait()
                    atTheUpdate(attempt)
                }
            }
            let taken = Texts()
            let turn = FlowTurn(
                agent: agent, prompt: [.text("hi")], onMessage: { _, _ in }, onSessionUpdate: { taken.add($0) },
                onClientOperation: {}, onSessionReady: { _ in }, control: FlowTurnControl(attempt: attempt))
            _ = try? await sessions.runIsolated(turn)
            return taken.value
        }
    }

    /// The text of each message chunk a turn takes in.
    private final class Texts: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        var value: [String] { lock.withLock { texts } }

        func add(_ notification: SessionNotification) {
            guard case .agentMessageChunk(let block) = notification.update, let text = block.text else { return }
            lock.withLock { texts.append(text) }
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let waiting = lock.withLock {
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            waiting.forEach { $0.resume() }
        }
    }
}

extension ACPAgentConnection {
    func setAfterPromptAnswer(_ hook: (@Sendable () async -> Void)?) {
        afterPromptAnswer = hook
    }
}
