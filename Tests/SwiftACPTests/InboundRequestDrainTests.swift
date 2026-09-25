@testable import SwiftACP
import Foundation
import JSONFoundation
import Testing

/// What the agent asks of the client while it answers a turn or a control belongs to
/// that exchange: it is answered — a turn's owned requests still open at its answer as
/// cancelled — before the exchange returns.
extension WriteGateTests {
    /// An agent can ask for a write and end its turn without awaiting the answer. The
    /// write belongs to the prompt in flight when it was read, and ends with it, as
    /// acpx's `clearActivePrompt` ends it (#130): at the answer it is answered `Request
    /// cancelled` — not decided after the turn returned, under the *next* turn's
    /// handlers — and it is neither counted nor written.
    @Test func aRequestItsAgentDidNotAwaitEndsWithTheTurn() async throws {
        struct FireAndForgetWriter: ACPAgentHandler {
            var path: String
            var requestRead: Signal
            func initialize(_ request: InitializeRequest) async -> InitializeResponse {
                InitializeResponse(agentInfo: Implementation(name: "hasty", version: "1.0"))
            }
            func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
                NewSessionResponse(sessionId: "hasty-session")
            }
            func prompt(
                _ request: PromptRequest, session: ACPServerSession
            ) async throws -> PromptResponse {
                Task { try? await session.writeTextFile(path: path, content: "x") }
                // End the turn as soon as the client has *read* the request — without
                // waiting for its answer.
                await requestRead.wait()
                return PromptResponse(stopReason: .endTurn)
            }
        }

        let root = try workspace()
        let requestRead = Signal()
        let cancelledSent = Signal()
        let release = Signal()
        var handlers = ACPClientHandlers.standard(permission: .denyAll)
        handlers.authorizeWrite = { _ in
            // Held past the answer: the write is still being served when the prompt ends.
            await release.wait()
            throw FileSystemPermissionError.denied
        }

        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(
            handler: FireAndForgetWriter(path: root + "/a.txt", requestRead: requestRead),
            transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(transport: clientTransport, handlers: handlers)
        await client.setWireObserver { line in
            if line.contains("\"method\":\"fs/write_text_file\"") { requestRead.fire() }
            if line.contains("\"code\":-32800") { cancelledSent.fire() }
        }
        await client.start()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: root))

        _ = try await client.prompt(PromptRequest(sessionId: session.sessionId, prompt: [.text("go")]))
        // The write was answered cancelled — the agent is told so — and not counted or done.
        await cancelledSent.wait()
        #expect(await client.permissionStats(for: session.sessionId).requested == 0)
        release.fire()
        #expect(!FileManager.default.fileExists(atPath: root + "/a.txt"))
        await client.close()
        serverTask.cancel()
    }

    /// So does a control (#101 review): an agent that asks the client for something
    /// while it answers `session/set_mode` or `session/set_config_option`, without
    /// awaiting the answer, has it answered under the control's handlers before the
    /// control returns — not under whatever the next caller puts in place.
    @Test(arguments: ["mode", "option"])
    func aControlWaitsForARequestItsAgentDidNotAwait(control: String) async throws {
        struct HastyControls: ACPAgentHandler {
            var path: String
            var requestRead: Signal
            func initialize(_ request: InitializeRequest) async -> InitializeResponse {
                InitializeResponse(agentInfo: Implementation(name: "hasty", version: "1.0"))
            }
            func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
                NewSessionResponse(sessionId: "hasty-session")
            }
            func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
                PromptResponse(stopReason: .endTurn)
            }
            func setMode(_ request: SetSessionModeRequest, session: ACPServerSession) async throws {
                Task { try? await session.writeTextFile(path: path, content: "x") }
                await requestRead.wait()
            }
            func setConfigOption(
                _ request: SetSessionConfigOptionRequest, session: ACPServerSession
            ) async throws -> SetSessionConfigOptionResponse {
                Task { try? await session.writeTextFile(path: path, content: "x") }
                await requestRead.wait()
                return SetSessionConfigOptionResponse()
            }
        }

        let root = try workspace()
        let requestRead = Signal()
        let release = Signal()
        let answered = Signal()
        var handlers = ACPClientHandlers.standard(permission: .denyAll)
        handlers.authorizeWrite = { _ in
            // Held until the control is waiting for it, as the turn's is above.
            await release.wait()
            answered.fire()
            throw FileSystemPermissionError.denied
        }

        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(
            handler: HastyControls(path: root + "/a.txt", requestRead: requestRead), transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(transport: clientTransport, handlers: handlers)
        await client.setWireObserver { line in
            if line.contains("\"method\":\"fs/write_text_file\"") { requestRead.fire() }
        }
        await client.inboundRequests.setOnWait { _ in release.fire() }
        await client.start()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: root))

        if control == "mode" {
            try await client.setMode(SetSessionModeRequest(sessionId: session.sessionId, modeId: "plan"))
        } else {
            try await client.setConfigOption(
                SetSessionConfigOptionRequest(sessionId: session.sessionId, configId: "effort", value: "high"))
        }
        #expect(answered.isFired)
        #expect(!FileManager.default.fileExists(atPath: root + "/a.txt"))
        release.fire()  // let a still-held handler finish before closing, should this fail
        await client.close()
        serverTask.cancel()
    }
}
