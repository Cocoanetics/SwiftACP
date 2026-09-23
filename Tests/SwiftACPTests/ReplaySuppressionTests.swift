@testable import SwiftACP
import Foundation
import JSONRPCPeer
import Testing

/// An agent answers `session/load` by replaying the session's history as
/// `session/update`s, and may go on after it answers. acpx waits for them to stop after
/// every load (`waitForSessionUpdateDrain`: 80 ms without one, at most 5 s), and when it
/// reconnects a session it neither shows nor delivers them (`suppressReplayUpdates`) —
/// the record already has that history.
struct ReplaySuppressionTests {
    /// Replays two updates for `session/load` before answering; then, when `trickle` is
    /// set, keeps sending one every `trickle`, `trickleCount` times — an agent still
    /// replaying after its answer. A prompt answers with one `after` chunk.
    struct ReplayingAgent: ACPAgentHandler {
        var trickle: Duration?
        var trickleCount = 0

        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(
                agentCapabilities: AgentCapabilities(loadSession: true),
                agentInfo: Implementation(name: "replayer", version: "1.0"))
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: "replay-session")
        }

        func loadSession(
            _ request: LoadSessionRequest, session: ACPServerSession
        ) async throws -> LoadSessionResponse {
            await session.update(.userMessageChunk(.text("earlier question")))
            await session.sendText("earlier answer")
            if let trickle {
                // Unstructured on purpose: the updates have to go on after this returns,
                // as a replay the agent has not finished does. Bounded by `trickleCount`.
                let count = trickleCount
                Task {
                    for _ in 0..<count {
                        try? await Task.sleep(for: trickle)
                        await session.sendText(".")
                    }
                }
            }
            return LoadSessionResponse()
        }

        func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
            await session.sendText("after")
            return PromptResponse(stopReason: .endTurn)
        }
    }

    /// A client connected to `agent` over a loopback, initialized.
    private func connect(_ agent: ReplayingAgent) async throws -> (ACPAgentConnection, Task<Void, Error>) {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: agent, transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(transport: clientTransport)
        await client.start()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        return (client, serverTask)
    }

    /// The text of every agent message chunk `stream` delivers until the subscription
    /// ends.
    private func texts(_ stream: AsyncStream<SessionNotification>) async -> [String] {
        var texts: [String] = []
        for await note in stream {
            if case .agentMessageChunk(let block) = note.update, let text = block.text { texts.append(text) }
        }
        return texts
    }

    @Test func aSuppressedLoadDeliversNoneOfTheReplay() async throws {
        let (client, server) = try await connect(ReplayingAgent())
        defer { server.cancel() }
        let (subscription, stream) = await client.makeSubscription()
        let delivered = Task { await texts(stream) }

        let previous = await client.applySessionUpdateSuppression(true)
        _ = try await client.loadSession(LoadSessionRequest(sessionId: "replay-session", cwd: "/"))
        try await client.waitForSessionUpdateDrain()
        await client.restoreSessionUpdateSuppression(previous)
        // Delivered in order: had any of the replay gone out, it would come first.
        _ = try await client.prompt(PromptRequest(sessionId: "replay-session", prompt: [.text("go")]))
        await client.endSubscription(subscription)

        #expect(await delivered.value == ["after"])
        await client.close()
    }

    @Test func anUnsuppressedLoadDeliversTheReplay() async throws {
        let (client, server) = try await connect(ReplayingAgent())
        defer { server.cancel() }
        let (subscription, stream) = await client.makeSubscription()
        let delivered = Task { await texts(stream) }

        _ = try await client.loadSession(LoadSessionRequest(sessionId: "replay-session", cwd: "/"))
        try await client.waitForSessionUpdateDrain()
        _ = try await client.prompt(PromptRequest(sessionId: "replay-session", prompt: [.text("go")]))
        await client.endSubscription(subscription)

        #expect(await delivered.value == ["earlier answer", "after"])
        await client.close()
    }

    /// The drain lasts until the replay has stopped: every update the agent sent after
    /// answering has arrived by the time it returns.
    @Test func theDrainWaitsForAReplayThatGoesOnAfterTheAnswer() async throws {
        let (client, server) = try await connect(ReplayingAgent(trickle: .milliseconds(5), trickleCount: 10))
        defer { server.cancel() }
        let (subscription, stream) = await client.makeSubscription()
        let delivered = Task { await texts(stream) }

        _ = try await client.loadSession(LoadSessionRequest(sessionId: "replay-session", cwd: "/"))
        try await client.waitForSessionUpdateDrain(idleMilliseconds: 200, timeoutMilliseconds: 10_000)
        await client.endSubscription(subscription)

        #expect(await delivered.value == ["earlier answer"] + Array(repeating: ".", count: 10))
        await client.close()
    }

    /// A replay that never stops fails the load, in acpx's words.
    @Test func aReplayThatDoesNotStopFailsTheDrain() async throws {
        let (client, server) = try await connect(ReplayingAgent(trickle: .milliseconds(5), trickleCount: 400))
        defer { server.cancel() }
        _ = try await client.loadSession(LoadSessionRequest(sessionId: "replay-session", cwd: "/"))

        let error = await #expect(throws: SessionReplayDrainTimeout.self) {
            try await client.waitForSessionUpdateDrain(idleMilliseconds: 200, timeoutMilliseconds: 400)
        }
        #expect(error?.localizedDescription == "Timed out waiting for session replay drain after 400ms")
        await client.close()
    }

    /// While suppressing, the tap hides the agent's `session/update` notifications and
    /// nothing else — acpx's `isSessionUpdateNotification` needs a `session/update`
    /// without an `id`.
    @Test func aSuppressingTapHidesOnlyTheAgentsSessionUpdates() {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var lines: [String] = []
        }
        let seen = Seen()
        let tap = RawWireTap { direction, body in
            seen.lock.withLock {
                seen.lines.append((direction == .inbound ? "in " : "out ") + String(decoding: body, as: UTF8.self))
            }
        }
        let update = #"{"jsonrpc":"2.0","method":"session/update","params":{}}"#
        let request = #"{"jsonrpc":"2.0","id":null,"method":"session/update","params":{}}"#
        let other = #"{"jsonrpc":"2.0","method":"session/other","params":{}}"#

        let previous = tap.applySessionUpdateSuppression(true)
        #expect(!previous)
        for line in [update, request, other] { tap.observe(.inbound, Data(line.utf8)) }
        tap.observe(.outbound, Data(update.utf8))
        tap.restoreSessionUpdateSuppression(previous)
        tap.observe(.inbound, Data(update.utf8))

        #expect(seen.lines == ["in " + request, "in " + other, "out " + update, "in " + update])
    }
}
