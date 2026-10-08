import Foundation
import JSONFoundation
import Testing
@testable import SwiftACP

@Test func extensionMethodAnswersUnknownClientRequests() async throws {
    let (clientEnd, agentEnd) = try LoopbackTransport.pair()
    let connection = ACPAgentConnection(
        transport: JSONRPCMessageTransport(agentEnd),
        handlers: ACPClientHandlers(
            extensionMethod: { method, _ in
                guard method == "cursor/ask_question" else { return nil }
                return .object(["outcome": .object(["outcome": .string("answered")])])
            }))
    await connection.start()
    let response = await connection.handleIncomingRequest(
        method: "cursor/ask_question",
        params: .object(["questions": .array([])]))
    guard case .success(let value) = response else {
        Issue.record("expected success, got \(response)")
        return
    }
    #expect(value == .object(["outcome": .object(["outcome": .string("answered")])]))
    await connection.close()
    clientEnd.close()
}
