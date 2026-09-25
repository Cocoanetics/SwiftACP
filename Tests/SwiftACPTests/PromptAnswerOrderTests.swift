@testable import SwiftACP
import Foundation
import JSONFoundation
import JSONRPCPeer
import Testing

/// A prompt's answer, and a request of the agent's, are announced in the order they
/// crossed the wire (#124), as acpx's formatter sees every message: an update the agent
/// sends straight after its answer comes after it, and a request it makes right before
/// comes before — however late the prompt's call resumes, or the request is served.
struct PromptAnswerOrderTests {
    /// Plays the agent on `agent`: answers the handshake and a new session, and a prompt
    /// with its answer — just after asking to read a file, when `asking` — and, at once
    /// after the answer, one more reply chunk.
    private static func playAgent(on agent: LoopbackTransport, asking: Bool = false) async throws {
        for try await message in agent.makeInboundStream() {
            guard case .request(let request) = message else { continue }
            let result: JSONValue
            switch request.method {
            case "initialize": result = try JSONValue(encoding: InitializeResponse())
            case "session/new": result = try JSONValue(encoding: NewSessionResponse(sessionId: "s"))
            case "session/prompt":
                if asking {
                    let read: JSONValue = .object(["sessionId": .string("s"), "path": .string("/nonexistent")])
                    try agent.send(.request(id: "r1", method: "fs/read_text_file", params: read))
                }
                let answer = try JSONValue(encoding: PromptResponse(stopReason: .endTurn))
                try agent.send(.response(id: request.id, result: answer))
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

    @Test(.timeLimit(.minutes(1)))
    func aRequestRightBeforeTheAnswerComesBeforeIt() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let agent = Task { try await Self.playAgent(on: agentEnd, asking: true) }
        defer { agent.cancel() }
        let client = ACPAgentConnection(transport: clientEnd, handlers: .standard(permission: .approveAll))
        let (answerSeen, answer) = AsyncStream<Void>.makeStream()
        // Serving the request starts only once the answer is out: a request announced
        // where it is served, rather than as it was read, would follow the answer.
        await client.setBeforeServingRequest { for await _ in answerSeen { break } }
        await client.start()
        _ = try await client.initialize(capabilities: ClientCapabilities(), clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: NSTemporaryDirectory()))
        let (subscription, stream) = await client.makeEventSubscription()
        let order = Task { () -> [String] in
            var seen: [String] = []
            for await event in stream {
                switch event {
                case .promptAnswered:
                    seen.append("answered")
                    answer.yield()
                case .inboundRequest(let request) where request.failure == nil:
                    seen.append(request.method)
                default: continue
                }
            }
            return seen
        }

        _ = try await client.prompt(PromptRequest(sessionId: session.sessionId, prompt: [.text("hi")]))
        await client.endSubscription(subscription)

        #expect(await order.value == ["fs/read_text_file", "answered"])
        await client.close()
    }
}

extension ACPAgentConnection {
    func setAfterPromptAnswer(_ hook: (@Sendable () async -> Void)?) {
        afterPromptAnswer = hook
    }

    func setBeforeServingRequest(_ hook: (@Sendable () async -> Void)?) {
        beforeServingRequest = hook
    }
}
