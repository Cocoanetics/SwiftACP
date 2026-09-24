@testable import SwiftACP
import Foundation
import JSONRPCPeer
import Testing

/// An agent answers `session/load` by replaying the session's history as
/// `session/update`s, and may go on after it answers. acpx waits for them to stop after
/// every load (`waitForSessionUpdateDrain`: 80 ms without one, at most 5 s), and when it
/// reconnects a session it neither shows nor delivers them (`suppressReplayUpdates`) —
/// the record already has that history. An acpx client holds one session; here both
/// are kept per session, so the other sessions of a connection carry on.
struct ReplaySuppressionTests {
    /// Replays two updates for `session/load` before answering; then, when `trickle` is
    /// set, keeps sending one every `trickle`, `trickleCount` times — an agent still
    /// replaying after its answer. A prompt answers with one `after` chunk.
    struct ReplayingAgent: ACPAgentHandler {
        var trickle: Duration?
        var trickleCount = 0
        /// Told each time a `session/load` reaches the agent.
        var onLoad: (@Sendable () -> Void)?

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
            onLoad?()
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

        await client.beginSuppressingReplay(of: "replay-session")
        _ = try await client.loadSession(LoadSessionRequest(sessionId: "replay-session", cwd: "/"))
        try await client.waitForSessionUpdateDrain(sessionId: "replay-session")
        await client.endSuppressingReplay(of: "replay-session")
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
        try await client.waitForSessionUpdateDrain(sessionId: "replay-session")
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
        try await client.waitForSessionUpdateDrain(
            sessionId: "replay-session", idleMilliseconds: 200, timeoutMilliseconds: 10_000)
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
            try await client.waitForSessionUpdateDrain(
                sessionId: "replay-session", idleMilliseconds: 200, timeoutMilliseconds: 400)
        }
        #expect(error?.localizedDescription == "Timed out waiting for session replay drain after 400ms")
        await client.close()
    }

    /// Keeping one session's replay back leaves the connection's other sessions alone:
    /// their updates are delivered, and do not hold up the first one's drain.
    @Test func suppressionAndTheDrainKeepToTheirSession() async throws {
        let (client, server) = try await connect(ReplayingAgent(trickle: .milliseconds(5), trickleCount: 400))
        defer { server.cancel() }
        let (subscription, stream) = await client.makeSubscription()
        let delivered = Task { await texts(stream) }

        await client.beginSuppressingReplay(of: "quiet-session")
        // Another session replays, then keeps sending updates.
        _ = try await client.loadSession(LoadSessionRequest(sessionId: "busy-session", cwd: "/"))
        try await client.waitForSessionUpdateDrain(
            sessionId: "quiet-session", idleMilliseconds: 100, timeoutMilliseconds: 400)
        await client.endSuppressingReplay(of: "quiet-session")
        await client.endSubscription(subscription)

        #expect(await delivered.value.first == "earlier answer")
        await client.close()
    }

    /// Suppression is counted: two loads of a session that overlap keep its replay back
    /// until both are done, whatever order they end in.
    @Test func overlappingSuppressionsLastUntilTheLastEnds() async throws {
        let (client, server) = try await connect(ReplayingAgent())
        defer { server.cancel() }
        let (subscription, stream) = await client.makeSubscription()
        let delivered = Task { await texts(stream) }

        await client.beginSuppressingReplay(of: "replay-session")
        await client.beginSuppressingReplay(of: "replay-session")
        await client.endSuppressingReplay(of: "replay-session")
        _ = try await client.loadSession(LoadSessionRequest(sessionId: "replay-session", cwd: "/"))
        try await client.waitForSessionUpdateDrain(sessionId: "replay-session")
        await client.endSuppressingReplay(of: "replay-session")
        _ = try await client.loadSession(LoadSessionRequest(sessionId: "replay-session", cwd: "/"))
        try await client.waitForSessionUpdateDrain(sessionId: "replay-session")
        await client.endSubscription(subscription)

        #expect(await delivered.value == ["earlier answer"])
        await client.close()
    }

    /// Loads of one session take turns. An ordinary load that comes while another load
    /// of the session keeps its replay back waits for it to finish, and gets its own
    /// replay, which it would otherwise lose inside the other's suppression.
    @Test func loadsOfOneSessionTakeTurns() async throws {
        let (loads, loaded) = AsyncStream<Void>.makeStream()
        let agent = ReplayingAgent(trickle: .milliseconds(5), trickleCount: 60, onLoad: { loaded.yield() })
        let (client, server) = try await connect(agent)
        defer { server.cancel() }
        let (subscription, stream) = await client.makeSubscription()
        let delivered = Task { await texts(stream) }
        let request = LoadSessionRequest(sessionId: "replay-session", cwd: "/")

        let suppressed = Task { try await client.loadSession(request, suppressReplayUpdates: true) }
        var reached = loads.makeAsyncIterator()
        _ = await reached.next()
        _ = try await client.loadSession(request, suppressReplayUpdates: false)
        _ = try await suppressed.value
        await client.endSubscription(subscription)

        #expect(await delivered.value.first == "earlier answer")
        await client.close()
    }

    /// An update that has been read but not yet handled holds the drain: ending the
    /// suppression then would deliver it after all. Once it is handled, the drain ends.
    @Test func theDrainWaitsForEveryUpdateReadToBeHandled() async throws {
        let (client, server) = try await connect(ReplayingAgent())
        defer { server.cancel() }
        client.sessionUpdates.arrived("replay-session")
        await #expect(throws: SessionReplayDrainTimeout.self) {
            try await client.waitForSessionUpdateDrain(
                sessionId: "replay-session", idleMilliseconds: 20, timeoutMilliseconds: 200)
        }
        client.sessionUpdates.finished("replay-session")
        try await client.waitForSessionUpdateDrain(
            sessionId: "replay-session", idleMilliseconds: 20, timeoutMilliseconds: 200)
        await client.close()
    }

    /// While suppressing a session, the tap hides that session's `session/update`
    /// notifications from the agent and nothing else — acpx's
    /// `isSessionUpdateNotification` needs a `session/update` without an `id`.
    @Test func aSuppressingTapHidesOnlyThatSessionsUpdates() {
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
        func update(_ session: String) -> String {
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(session)","update":{}}}"#
        }
        let request = #"{"jsonrpc":"2.0","id":null,"method":"session/update","params":{"sessionId":"a"}}"#
        let other = #"{"jsonrpc":"2.0","method":"session/other","params":{"sessionId":"a"}}"#

        tap.beginSuppressingReplay(of: "a")
        tap.beginSuppressingReplay(of: "a")
        for line in [update("a"), update("b"), request, other] { tap.observe(.inbound, Data(line.utf8)) }
        tap.observe(.outbound, Data(update("a").utf8))
        tap.endSuppressingReplay(of: "a")
        tap.observe(.inbound, Data(update("a").utf8))
        tap.endSuppressingReplay(of: "a")
        tap.observe(.inbound, Data(update("a").utf8))

        #expect(seen.lines == [
            "in " + update("b"), "in " + request, "in " + other, "out " + update("a"), "in " + update("a")
        ])
    }
}
