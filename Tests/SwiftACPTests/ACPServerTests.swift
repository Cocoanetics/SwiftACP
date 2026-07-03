import Foundation
import SwiftACP
import Testing

/// Validates the ACP **agent/server** half end-to-end by wiring the real ACP
/// client (`ACPAgentConnection`) to an `ACPAgentServer` over an in-process
/// `LoopbackTransport` — no subprocess. Exercises the full surface: initialize,
/// session/new, streamed updates (plan/tool/text), usage on the response,
/// cancellation, and the agent→client permission callback.
struct ACPServerTests {
    /// A stateless reference handler used to drive the protocol. Branches on the
    /// prompt text so one handler covers every case.
    struct EchoHandler: ACPAgentHandler {
        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(
                agentCapabilities: AgentCapabilities(loadSession: false),
                agentInfo: Implementation(name: "test-agent", version: "0.1.0"),
                authMethods: [])
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(
                sessionId: "session-1",
                modelState: SessionModelState(
                    currentModelId: "test-model",
                    availableModels: [
                        ModelInfo(modelId: "test-model", name: "Test"),
                        ModelInfo(modelId: "alt-model", name: "Alt")
                    ]))
        }

        func setModel(_ request: SetSessionModelRequest) async throws {
            // Accept only advertised ids; anything else is rejected like a bad switch.
            guard ["test-model", "alt-model"].contains(request.modelId) else {
                throw JSONRPCErrorBody(code: -32602, message: "unknown model: \(request.modelId)")
            }
        }

        func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
            let text = request.prompt.compactMap(\.text).joined()

            if text.contains("wait") {
                // Announce that the turn is running (the test awaits this update
                // before cancelling), then sleep long enough that only cancellation
                // can end the turn; cancellation surfaces as .cancelled.
                await session.sendText("waiting")
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return PromptResponse(stopReason: .endTurn)
            }

            if text.contains("permission") {
                let response = try await session.requestPermission(
                    toolCall: ToolCallUpdate(toolCallId: "danger-1", title: "rm -rf"),
                    options: [PermissionOption(optionId: "allow", name: "Allow", kind: .allowOnce)])
                let approved = if case .selected = response.outcome { true } else { false }
                await session.sendText(approved ? "approved" : "denied")
                return PromptResponse(stopReason: .endTurn)
            }

            await session.sendPlan([
                PlanEntry(content: "Read", status: .completed),
                PlanEntry(content: "Reply", status: .inProgress)
            ])
            await session.sendToolCall(
                ToolCall(toolCallId: "call-1", title: "echo", kind: .other, status: .inProgress))
            await session.sendToolCallUpdate(ToolCallUpdate(toolCallId: "call-1", status: .completed))
            for word in ("You said: " + text).split(separator: " ") {
                await session.sendText(String(word) + " ")
            }
            return PromptResponse(
                stopReason: .endTurn,
                usage: PromptUsage(inputTokens: 12, outputTokens: 34, totalTokens: 46))
        }

        func availableCommands(for _: SessionId) async -> [AvailableCommand] {
            [AvailableCommand(name: "new", description: "Start fresh")]
        }
    }

    /// Spin up a connected client↔server pair over a loopback transport. The
    /// returned task retains the server for the test's lifetime.
    private func makePair() async -> (client: ACPAgentConnection, serverTask: Task<Void, Error>) {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: EchoHandler(), transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(
            transport: clientTransport, handlers: .standard(permission: .approveAll))
        await client.start()
        return (client, serverTask)
    }

    actor Collected {
        var text = ""
        var sawPlan = false
        var toolCalls = 0
        func append(_ string: String) { text += string }
        func plan() { sawPlan = true }
        func tool() { toolCalls += 1 }
    }

    @Test func fullPromptRoundTripWithUsage() async throws {
        let (client, serverTask) = await makePair()

        let info = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        #expect(info.agentInfo?.name == "test-agent")

        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))
        #expect(session.sessionId == "session-1")

        let collected = Collected()
        let (subscriptionId, stream) = await client.makeSubscription()
        let consumer = Task {
            for await note in stream where note.sessionId == session.sessionId {
                switch note.update {
                case .agentMessageChunk(let block): if let text = block.text { await collected.append(text) }
                case .plan: await collected.plan()
                case .toolCall: await collected.tool()
                default: break
                }
            }
        }

        let response = try await client.prompt(
            PromptRequest(sessionId: session.sessionId, prompt: [.text("hi")]))
        await client.endSubscription(subscriptionId)
        await consumer.value

        #expect(response.stopReason == .endTurn)
        #expect(response.usage?.totalTokens == 46)
        #expect(response.usage?.inputTokens == 12)
        #expect(await collected.text == "You said: hi ")
        #expect(await collected.sawPlan)
        #expect(await collected.toolCalls == 1)

        await client.close()
        serverTask.cancel()
    }

    @Test func cancellationReturnsCancelledStopReason() async throws {
        let (client, serverTask) = await makePair()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))

        // Subscribe before prompting: the handler announces the running turn with a
        // "waiting" update, so awaiting it (instead of sleeping) guarantees the
        // prompt has reached the server before we cancel.
        let (subscriptionId, stream) = await client.makeSubscription()
        let turnStarted = Task {
            for await note in stream where note.sessionId == session.sessionId {
                if case .agentMessageChunk = note.update { return }
            }
        }
        let promptTask = Task {
            try await client.prompt(PromptRequest(sessionId: session.sessionId, prompt: [.text("please wait")]))
        }
        await turnStarted.value
        try await client.cancel(sessionId: session.sessionId)

        let response = try await promptTask.value
        await client.endSubscription(subscriptionId)
        #expect(response.stopReason == .cancelled)

        await client.close()
        serverTask.cancel()
    }

    @Test func permissionCallbackRoundTrips() async throws {
        let (client, serverTask) = await makePair()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))

        let collected = Collected()
        let (subscriptionId, stream) = await client.makeSubscription()
        let consumer = Task {
            for await note in stream where note.sessionId == session.sessionId {
                if case .agentMessageChunk(let block) = note.update, let text = block.text {
                    await collected.append(text)
                }
            }
        }

        let response = try await client.prompt(
            PromptRequest(sessionId: session.sessionId, prompt: [.text("needs permission")]))
        await client.endSubscription(subscriptionId)
        await consumer.value

        #expect(response.stopReason == .endTurn)
        // The client's `.approveAll` policy selected an allow option.
        #expect(await collected.text == "approved")

        await client.close()
        serverTask.cancel()
    }

    @Test func advertisesAvailableCommandsOnNewSession() async throws {
        let (client, serverTask) = await makePair()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)

        // Subscribe before session/new, then await the first commands update — the
        // server publishes it as a notification after the new-session reply.
        let (subscriptionId, stream) = await client.makeSubscription()
        let firstCommands = Task { () -> [AvailableCommand]? in
            for await note in stream {
                if case .availableCommandsUpdate(let commands) = note.update { return commands }
            }
            return nil
        }

        _ = try await client.newSession(NewSessionRequest(cwd: "/tmp"))
        let received = await firstCommands.value
        await client.endSubscription(subscriptionId)

        #expect(received?.map(\.name) == ["new"])

        await client.close()
        serverTask.cancel()
    }

    @Test func newSessionAdvertisesModelsAndSetModelRoundTrips() async throws {
        let (client, serverTask) = await makePair()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)

        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))
        // The typed model menu round-trips through the passthrough `models` field.
        let state = try session.models?.decoded(SessionModelState.self)
        #expect(state?.currentModelId == "test-model")
        #expect(state?.availableModels.map(\.modelId) == ["test-model", "alt-model"])

        // A switch to an advertised id succeeds.
        try await client.setModel(SetSessionModelRequest(sessionId: session.sessionId, modelId: "alt-model"))

        // A switch to an unknown id surfaces the handler's rejection as an error.
        await #expect(throws: (any Error).self) {
            try await client.setModel(
                SetSessionModelRequest(sessionId: session.sessionId, modelId: "nope"))
        }

        await client.close()
        serverTask.cancel()
    }
}
