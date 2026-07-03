import Foundation
import JSONFoundation
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
                    ]),
                modes: SessionModeState(
                    currentModeId: "code",
                    availableModes: [
                        SessionMode(id: "code", name: "Code"),
                        SessionMode(id: "plan", name: "Plan", description: "Read-only")
                    ]),
                configOptions: [Self.verboseConfigOption(current: "off")])
        }

        func setModel(_ request: SetSessionModelRequest) async throws {
            // Accept only advertised ids; anything else is rejected like a bad switch.
            guard ["test-model", "alt-model"].contains(request.modelId) else {
                throw JSONRPCErrorBody(code: -32602, message: "unknown model: \(request.modelId)")
            }
        }

        func setMode(_ request: SetSessionModeRequest, session: ACPServerSession) async throws {
            guard ["code", "plan"].contains(request.modeId) else {
                throw JSONRPCErrorBody(code: -32602, message: "unknown mode: \(request.modeId)")
            }
            // Confirm the switch by streaming a current_mode_update.
            await session.sendModeUpdate(request.modeId)
        }

        func setConfigOption(
            _ request: SetSessionConfigOptionRequest, session: ACPServerSession
        ) async throws -> SetSessionConfigOptionResponse {
            guard request.configId == "verbose", ["on", "off"].contains(request.value) else {
                throw JSONRPCErrorBody(code: -32602, message: "bad config: \(request.configId)")
            }
            // Echo back the full option set reflecting the new value.
            return SetSessionConfigOptionResponse(
                configOptions: [Self.verboseConfigOption(current: request.value)])
        }

        /// A "select" config option acpx recognises (`type`/`id`/`currentValue`/`options`).
        static func verboseConfigOption(current: String) -> JSONValue {
            .object([
                "id": .string("verbose"),
                "type": .string("select"),
                "name": .string("Verbose"),
                "currentValue": .string(current),
                "options": .array([
                    .object(["id": .string("on"), "name": .string("On")]),
                    .object(["id": .string("off"), "name": .string("Off")])
                ])
            ])
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

    /// A handler that overrides only the *legacy* `setMode(_:)` / `setConfigOption(_:)`
    /// hooks (no session handle) — as an agent written against the pre-session-aware
    /// API would. The server dispatches to the session-aware variants, whose defaults
    /// must forward here, so these overrides still run after upgrading.
    struct LegacyHandler: ACPAgentHandler {
        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(agentInfo: Implementation(name: "legacy", version: "0.1.0"))
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: "legacy-1")
        }

        func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
            PromptResponse(stopReason: .endTurn)
        }

        func setMode(_ request: SetSessionModeRequest) async throws {
            // Accept only "plan"; the default (unoverridden) would reject everything.
            guard request.modeId == "plan" else {
                throw JSONRPCErrorBody(code: -32602, message: "legacy rejects \(request.modeId)")
            }
        }

        func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {
            guard request.configId == "verbose" else {
                throw JSONRPCErrorBody(code: -32602, message: "legacy rejects \(request.configId)")
            }
        }
    }

    /// Spin up a connected client↔server pair over a loopback transport. The
    /// returned task retains the server for the test's lifetime.
    private func makePair(
        _ handler: some ACPAgentHandler = EchoHandler()
    ) async -> (client: ACPAgentConnection, serverTask: Task<Void, Error>) {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: handler, transport: serverTransport)
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

    @Test func newSessionAdvertisesModesAndSetModeEmitsUpdate() async throws {
        let (client, serverTask) = await makePair()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)

        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))
        // The mode menu rides on the typed `modes` field.
        #expect(session.modes?.currentModeId == "code")
        #expect(session.modes?.availableModes.map(\.id) == ["code", "plan"])

        // Subscribe so we catch the current_mode_update the handler streams back.
        let (subscriptionId, stream) = await client.makeSubscription()
        let modeUpdate = Task { () -> String? in
            for await note in stream where note.sessionId == session.sessionId {
                if case .currentModeUpdate(let modeId) = note.update { return modeId }
            }
            return nil
        }

        try await client.setMode(SetSessionModeRequest(sessionId: session.sessionId, modeId: "plan"))
        let received = await modeUpdate.value
        await client.endSubscription(subscriptionId)
        #expect(received == "plan")

        // An unknown mode surfaces the handler's rejection.
        await #expect(throws: (any Error).self) {
            try await client.setMode(
                SetSessionModeRequest(sessionId: session.sessionId, modeId: "nope"))
        }

        await client.close()
        serverTask.cancel()
    }

    @Test func setConfigOptionReturnsUpdatedOptions() async throws {
        let (client, serverTask) = await makePair()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))

        // The advertised option starts at "off".
        let advertised = session.configOptions?.first
        #expect(advertised?["id"]?.stringValue == "verbose")
        #expect(advertised?["currentValue"]?.stringValue == "off")

        // Setting it round-trips the full updated option set (not an empty response).
        let response = try await client.setConfigOption(
            SetSessionConfigOptionRequest(sessionId: session.sessionId, configId: "verbose", value: "on"))
        #expect(response.configOptions?.first?["currentValue"]?.stringValue == "on")

        // A bad option is rejected.
        await #expect(throws: (any Error).self) {
            _ = try await client.setConfigOption(
                SetSessionConfigOptionRequest(sessionId: session.sessionId, configId: "verbose", value: "maybe"))
        }

        await client.close()
        serverTask.cancel()
    }

    @Test func legacySessionControlHooksStillDispatch() async throws {
        // An agent that overrode only the pre-session-aware hooks must keep working:
        // the server's session-aware call forwards to the legacy override.
        let (client, serverTask) = await makePair(LegacyHandler())
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))

        // Reaches the legacy setMode override (default would reject every mode).
        try await client.setMode(SetSessionModeRequest(sessionId: session.sessionId, modeId: "plan"))
        // Reaches the legacy setConfigOption override; the session-aware default
        // wraps its Void result in an empty response.
        let response = try await client.setConfigOption(
            SetSessionConfigOptionRequest(sessionId: session.sessionId, configId: "verbose", value: "on"))
        #expect(response.configOptions == nil)

        // The legacy override's own rejection still surfaces (proving it ran, not
        // the "not supported" default).
        await #expect(throws: (any Error).self) {
            try await client.setMode(SetSessionModeRequest(sessionId: session.sessionId, modeId: "code"))
        }

        await client.close()
        serverTask.cancel()
    }

    @Test func sessionControlsOnUnknownSessionError() async throws {
        let (client, serverTask) = await makePair()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)

        // set_mode / set_config_option before any session/new must not crash the
        // server — they surface an "unknown session" JSON-RPC error.
        await #expect(throws: (any Error).self) {
            try await client.setMode(SetSessionModeRequest(sessionId: "ghost", modeId: "plan"))
        }
        await #expect(throws: (any Error).self) {
            _ = try await client.setConfigOption(
                SetSessionConfigOptionRequest(sessionId: "ghost", configId: "verbose", value: "on"))
        }

        await client.close()
        serverTask.cancel()
    }
}
