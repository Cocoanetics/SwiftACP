import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// ``PromptOutcome`` is the only thing a client ever sees from ``ACPSession/run(_:meta:onUpdate:)``,
/// so `_meta` reaching ``PromptResponse`` (#314) is useless to a caller unless `run` forwards it
/// too. These drive a real turn through a loopback agent to prove it does (MC#397's blocker).
struct PromptOutcomeMetaTests {
    /// Answers the handshake and a new session, then a prompt with the given raw `result` JSON.
    private static func playAgent(on agent: LoopbackTransport, promptResult: String) async throws {
        for try await message in agent.makeInboundStream() {
            guard case .request(let request) = message else { continue }
            switch request.method {
            case "initialize":
                try agent.send(.response(id: request.id, result: try JSONValue(encoding: InitializeResponse())))
            case "session/new":
                try agent.send(
                    .response(id: request.id, result: try JSONValue(encoding: NewSessionResponse(sessionId: "s"))))
            case "session/prompt":
                let result = try JSONDecoder().decode(JSONValue.self, from: Data(promptResult.utf8))
                try agent.send(.response(id: request.id, result: result))
            default:
                try agent.send(.response(id: request.id, result: .object([:])))
            }
        }
    }

    private static func connectedAgent(playing promptResult: String) async throws -> (ACPAgent, Task<Void, Error>) {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let playTask = Task { try await Self.playAgent(on: agentEnd, promptResult: promptResult) }
        let connection = ACPAgentConnection(transport: clientEnd)
        await connection.start()
        let info = try await connection.initialize(capabilities: ClientCapabilities(), clientInfo: .acpx)
        let agent = ACPAgent(
            name: "mock", cwd: NSTemporaryDirectory(), connection: connection,
            transport: clientEnd, rawWire: RawWireTap(), initializeResult: info)
        return (agent, playTask)
    }

    @Test(.timeLimit(.minutes(1)))
    func runForwardsTheResponsesMetaOntoTheOutcome() async throws {
        let json =
            #"{"stopReason":"end_turn","#
            + #""_meta":{"quota":{"model_usage":[{"model":"claude-opus-5-5","token_count":{"totalTokens":1}}]}}}"#
        let (agent, playTask) = try await Self.connectedAgent(playing: json)
        defer { playTask.cancel() }
        let session = try await agent.newSession()

        let outcome = try await session.run("hi")

        #expect(outcome.meta?["quota"]?["model_usage"]?.arrayValue?.first?["model"]?.stringValue
            == "claude-opus-5-5")
    }

    @Test(.timeLimit(.minutes(1)))
    func runLeavesTheOutcomesMetaNilWhenTheResponseHasNone() async throws {
        let (agent, playTask) = try await Self.connectedAgent(playing: #"{"stopReason":"end_turn"}"#)
        defer { playTask.cancel() }
        let session = try await agent.newSession()

        let outcome = try await session.run("hi")

        #expect(outcome.meta == nil)
        #expect(outcome.usage == nil)
        #expect(outcome.sessionFailure == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func runPreservesExplicitCancelledAndUnknownStopReasonsWithUsageAndMeta() async throws {
        let cancelledJSON =
            #"{"stopReason":"cancelled","usage":{"input_tokens":12,"output_tokens":0,"#
            + #""thought_tokens":8,"total_tokens":20},"_meta":{"source":"synthetic-cancel"}}"#
        let (cancelledAgent, cancelledTask) = try await Self.connectedAgent(playing: cancelledJSON)
        defer { cancelledTask.cancel() }
        let cancelledSession = try await cancelledAgent.newSession()

        let cancelledOutcome = try await cancelledSession.run("hi")
        #expect(cancelledOutcome.stopReason == .cancelled)
        #expect(cancelledOutcome.text.isEmpty)
        #expect(cancelledOutcome.usage?.thoughtTokens == 8)
        #expect(cancelledOutcome.usage?.totalTokens == 20)
        #expect(cancelledOutcome.meta == .object(["source": .string("synthetic-cancel")]))
        #expect(cancelledOutcome.sessionFailure == nil)
        #expect(cancelledOutcome.clientOperations.isEmpty)

        let unknownJSON =
            #"{"stopReason":"adapter_custom_stop","_meta":{"detail":"preserved"}}"#
        let (unknownAgent, unknownTask) = try await Self.connectedAgent(playing: unknownJSON)
        defer { unknownTask.cancel() }
        let unknownSession = try await unknownAgent.newSession()

        let unknownOutcome = try await unknownSession.run("hi")
        #expect(unknownOutcome.stopReason == StopReason(rawValue: "adapter_custom_stop"))
        #expect(unknownOutcome.text.isEmpty)
        #expect(unknownOutcome.usage == nil)
        #expect(unknownOutcome.meta == .object(["detail": .string("preserved")]))
        #expect(unknownOutcome.sessionFailure == nil)
        #expect(unknownOutcome.clientOperations.isEmpty)
    }
}
