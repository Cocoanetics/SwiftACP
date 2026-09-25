@testable import SwiftACP
import Foundation
import JSONFoundation
import JSONRPCPeer
import Testing

/// A prompt's answer is announced in the order it crossed the wire (#124): an update the
/// agent sends straight after its answer comes after it, as acpx's formatter sees the
/// two — however late the call that sent the prompt resumes.
struct PromptAnswerOrderTests {
    /// Plays the agent on `agent`: answers the handshake and a new session, and a prompt
    /// with its answer and, at once after it, one more reply chunk.
    private static func playAgent(on agent: LoopbackTransport) async throws {
        for try await message in agent.makeInboundStream() {
            guard case .request(let request) = message else { continue }
            let result: JSONValue
            switch request.method {
            case "initialize": result = try JSONValue(encoding: InitializeResponse())
            case "session/new": result = try JSONValue(encoding: NewSessionResponse(sessionId: "s"))
            case "session/prompt":
                try agent.send(.response(id: request.id, result: try JSONValue(encoding: PromptResponse(stopReason: .endTurn))))
                let late = SessionNotification(sessionId: "s", update: .agentMessageChunk(.text("late")))
                try agent.send(.notification(method: "session/update", params: try JSONValue(encoding: late)))
                continue
            default: result = .object([:])
            }
            try agent.send(.response(id: request.id, result: result))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func anUpdateRightAfterTheAnswerComesAfterIt() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let agent = Task { try await Self.playAgent(on: agentEnd) }
        defer { agent.cancel() }
        let client = ACPAgentConnection(transport: clientEnd, handlers: .standard(permission: .approveAll))
        let (lateSeen, late) = AsyncStream<Void>.makeStream()
        // The prompt's caller resumes only once the update after the answer is out: an
        // answer announced from the call, rather than as it was read, would follow it.
        await client.setAfterPromptAnswer { for await _ in lateSeen { break } }
        await client.start()
        _ = try await client.initialize(capabilities: ClientCapabilities(), clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: NSTemporaryDirectory()))
        let (subscription, stream) = await client.makeEventSubscription()
        let order = Task { () -> [String] in
            var seen: [String] = []
            for await event in stream {
                switch event {
                case .promptAnswered: seen.append("answered")
                case .update(let note):
                    guard case .agentMessageChunk(let block) = note.update, block.text == "late" else { continue }
                    seen.append("late")
                    late.yield()
                default: continue
                }
            }
            return seen
        }

        _ = try await client.prompt(PromptRequest(sessionId: session.sessionId, prompt: [.text("hi")]))
        await client.endSubscription(subscription)

        #expect(await order.value == ["answered", "late"])
        await client.close()
    }
}

extension ACPAgentConnection {
    func setAfterPromptAnswer(_ hook: (@Sendable () async -> Void)?) {
        afterPromptAnswer = hook
    }
}
