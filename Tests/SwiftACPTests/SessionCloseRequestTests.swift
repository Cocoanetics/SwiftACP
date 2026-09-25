#if os(macOS) || os(Linux)
@testable import SwiftACP
import Foundation
import JSONFoundation
import JSONRPCPeer
import Testing

// What the agent asks for a session this client is closing, as acpx 0.19.1's client
// answers it (#160): a permission question, a file read or write, starting a command —
// owned by a prompt or not — is answered cancelled (`assertActive`), and one still being
// served when the close goes out is ended then (`abortSessionRequests`).
extension RequestOwnershipTests {
    /// An agent that reacts to `session/close` by asking a question, writing a file and
    /// starting a command is refused all three, before the close is answered.
    @Test(.timeLimit(.minutes(1)))
    func whatTheAgentAsksForASessionBeingClosedIsRefused() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let root = try ChildSpawnTests.workspace()
        var script = Script { _ in [] }
        script.onClose = { close in [
            .request(id: "q1", method: "session/request_permission", params: Self.permission),
            .request(id: "w1", method: "fs/write_text_file", params: .object([
                "sessionId": .string("s"), "path": .string(root + "/out.txt"), "content": .string("x")
            ])),
            .request(id: "c1", method: "terminal/create", params: .object([
                "sessionId": .string("s"), "command": .string("/bin/echo")
            ])),
            .response(id: close, result: .object([:]))
        ] }
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: answers, script: script) }
        defer { agent.cancel() }
        let asked = Flag()
        var handlers = ACPClientHandlers.standard(permission: .approveAll)
        handlers.requestPermission = { _ in
            asked.set()
            return RequestPermissionResponse(outcome: .selected(optionId: "allow"))
        }
        let client = try await Self.client(clientEnd, handlers: handlers, terminals: root)

        try await client.closeSession(CloseSessionRequest(sessionId: "s"))

        guard case .response(let question) = await answers.wait(for: "q1") else { throw CancellationError() }
        #expect(try #require(question.result).decoded(RequestPermissionResponse.self).outcome == .cancelled)
        for id: JSONRPCID in ["w1", "c1"] {
            guard case .errorResponse(let failure) = await answers.wait(for: id) else {
                Issue.record("\(id) was served")
                continue
            }
            #expect(failure.error.code == -32800)
        }
        #expect(!asked.isSet)
        #expect(!FileManager.default.fileExists(atPath: root + "/out.txt"))
        #expect(await client.permissionStats(for: "s").requested == 0)
        await client.close()
    }

    /// A question the agent asked with no prompt in flight, still being asked when the
    /// session is closed, is answered `cancelled` then — and counted so, as acpx's
    /// `finishPermissionRequest` counts it.
    @Test(.timeLimit(.minutes(1)))
    func aQuestionOpenAtTheCloseIsAnsweredCancelled() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: answers, script: Script { _ in [] }) }
        defer { agent.cancel() }
        let (asked, askedNoted) = AsyncStream<Void>.makeStream()
        let (decided, decide) = AsyncStream<Void>.makeStream()
        var handlers = ACPClientHandlers.standard(permission: .approveAll)
        handlers.requestPermission = { _ in
            askedNoted.yield()
            for await _ in decided { break }
            return RequestPermissionResponse(outcome: .selected(optionId: "allow"))
        }
        let client = try await Self.client(clientEnd, handlers: handlers)

        try agentEnd.send(.request(id: "q1", method: "session/request_permission", params: Self.permission))
        for await _ in asked { break }
        try await client.closeSession(CloseSessionRequest(sessionId: "s"))
        decide.finish()

        guard case .response(let response) = await answers.wait(for: "q1") else { throw CancellationError() }
        #expect(try #require(response.result).decoded(RequestPermissionResponse.self).outcome == .cancelled)
        let stats = await client.permissionStats(for: "s")
        #expect(stats.requested == 1 && stats.cancelled == 1 && stats.approved == 0, "\(stats)")
        await client.close()
    }
}
#endif
