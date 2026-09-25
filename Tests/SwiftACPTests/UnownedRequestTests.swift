#if os(macOS) || os(Linux)
@testable import SwiftACP
import Foundation
import JSONFoundation
import JSONRPCPeer
import Testing

// What becomes of a request the agent sends with no prompt in flight, as acpx 0.19.1's
// client serves it (#163): what serves it listens to the session's fallback controller,
// which acpx aborts at every cancel, at a prompt's end and at a close
// (`takePermissionAbortController`). One still being served then is answered cancelled,
// and a permission question is counted so (`finishPermissionRequest`).
extension RequestOwnershipTests {
    /// A permission question the client's handler holds until `decide` finishes, asked
    /// while no prompt is in flight.
    private struct HeldQuestion {
        var client: ACPAgentConnection
        var answers: Answers
        var decide: AsyncStream<Void>.Continuation
        var agent: Task<Void, any Error>
    }

    private static func questionAskedWithNoPrompt(_ script: Script) async throws -> HeldQuestion {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let agent = Task { try await playAgent(on: agentEnd, answers: answers, script: script) }
        let (asked, askedNoted) = AsyncStream<Void>.makeStream()
        let (decided, decide) = AsyncStream<Void>.makeStream()
        var handlers = ACPClientHandlers.standard(permission: .approveAll)
        handlers.requestPermission = { _ in
            askedNoted.yield()
            for await _ in decided { break }
            return RequestPermissionResponse(outcome: .selected(optionId: "allow"))
        }
        let client = try await client(clientEnd, handlers: handlers)
        try agentEnd.send(.request(id: "q1", method: "session/request_permission", params: permission))
        for await _ in asked { break }
        return HeldQuestion(client: client, answers: answers, decide: decide, agent: agent)
    }

    /// The question was answered `cancelled`, and counted as that alone.
    private static func expectCancelled(_ held: HeldQuestion) async throws {
        guard case .response(let response) = await held.answers.wait(for: "q1") else { throw CancellationError() }
        #expect(try #require(response.result).decoded(RequestPermissionResponse.self).outcome == .cancelled)
        let stats = await held.client.permissionTotals(for: "s")
        #expect(stats.requested == 1 && stats.cancelled == 1 && stats.approved == 0, "\(stats)")
        await held.client.close()
    }

    /// A cancel ends the question though no prompt is in flight to cancel.
    @Test(.timeLimit(.minutes(1)))
    func aQuestionOpenAtACancelIsAnsweredCancelled() async throws {
        let held = try await Self.questionAskedWithNoPrompt(Script { _ in [] })
        defer { held.agent.cancel() }

        try await held.client.cancel(sessionId: "s")
        held.decide.finish()

        try await Self.expectCancelled(held)
    }

    /// A prompt's end ends the question though the prompt never owned it.
    @Test(.timeLimit(.minutes(1)))
    func aQuestionOpenAtAPromptsEndIsAnsweredCancelled() async throws {
        let held = try await Self.questionAskedWithNoPrompt(Script { prompt in [try Self.answer(prompt)] })
        defer { held.agent.cancel() }
        // The turn waits for the question before it ends: should its end leave the question
        // open, the handler decides it then.
        await held.client.inboundRequests.setOnWait { _ in held.decide.finish() }

        _ = try await held.client.prompt(PromptRequest(sessionId: "s", prompt: [.text("hi")]))
        held.decide.finish()

        try await Self.expectCancelled(held)
    }
}
#endif
