import Foundation
import JSONFoundation
import JSONRPCPeer
@testable import SwiftACP
import Testing

/// Regression suite for Antigravity thought-only `end_turn` completions, mixed thought/message
/// turns, explicit cancelled/unknown stop reasons, and independent preservation of terminal
/// `_meta`/`usage` alongside permission outcomes and client-operation notices (#346, part of #343).
///
/// Issue #343 / #346 includes a sanitized permission example but no attached full raw wire
/// transcript for background run `93DBBF66-36BA-4AF3-8273-A3BA1F2E59F9`. Every multi-message
/// wire sequence below is therefore explicitly marked as a **synthetic** reconstruction of that
/// reported trace rather than a verbatim captured fixture.
@Suite(.timeLimit(.minutes(1)))
struct AntigravityTurnCompletionTests {
    /// Synchronous callback recorder so `onUpdate` / `onClientOperation` assertions never race
    /// against `Task { ... }` scheduling.
    private final class SyncRecorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Value] = []
        func append(_ item: Value) { lock.withLock { items.append(item) } }
        var values: [Value] { lock.withLock { items } }
    }

    /// Raw JSON-RPC wire step the synthetic Antigravity agent sends during `session/prompt`.
    private enum PromptWireStep: Sendable {
        /// A `session/update` notification whose `params` JSON is sent verbatim.
        case update(String)
        /// A `session/request_permission` request sent to the client; awaits its reply before continuing.
        case permissionRequest(String)
    }

    private struct SyntheticTurnResult {
        var outcome: PromptOutcome
        var updates: [SessionUpdate]
        var operations: [ClientOperation]
        var inboundRequests: [InboundRequest]
        var permissionResponses: [RequestPermissionResponse]
        var connectionEvents: [String]
        var permissionStats: PermissionStats
        var wireLines: [String]
    }

    /// Plays a raw JSON-RPC agent over `LoopbackTransport` answering `initialize` as
    /// `antigravity-acp`, `session/new`, and one `session/prompt` using raw JSON envelopes so
    /// tests exercise the real decoder, wire-ordering hooks, and `ACPSession.run` pipeline.
    private static func runSyntheticTurn(
        agentName: String = AntigravityCompat.agentName,
        sessionId: SessionId = "antigravity-synthetic-session",
        steps: [PromptWireStep],
        promptResultJSON: String,
        policy: PermissionPolicy = .approveAll
    ) async throws -> SyntheticTurnResult {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let permissionReplies = SyncRecorder<RequestPermissionResponse>()
        let serverPeer = JSONRPCPeer(transport: agentEnd)
        await serverPeer.setHandlers(
            request: { method, _ in
                await Self.handleSyntheticAgentRequest(
                    method: method, agentName: agentName, sessionId: sessionId,
                    steps: steps, promptResultJSON: promptResultJSON,
                    peer: serverPeer, permissionReplies: permissionReplies)
            },
            notification: { _, _ in })
        await serverPeer.start()

        let connection = ACPAgentConnection(
            transport: clientEnd,
            handlers: .standard(permission: policy, nonInteractivePermissions: .deny, terminal: .none))
        let wireLines = SyncRecorder<String>()
        await connection.setWireObserver { line in wireLines.append(line) }
        await connection.start()
        let info = try await connection.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let agent = ACPAgent(
            name: "antigravity", cwd: NSTemporaryDirectory(), connection: connection,
            transport: clientEnd, rawWire: RawWireTap(), initializeResult: info)
        let session = try await agent.newSession()

        let (subId, eventStream) = await connection.makeEventSubscription()
        let eventOrderTask = Task { () -> [String] in
            var labels: [String] = []
            for await event in eventStream {
                labels.append(Self.eventLabel(event))
            }
            return labels
        }

        let updates = SyncRecorder<SessionUpdate>()
        let operations = SyncRecorder<ClientOperation>()
        let inboundRequests = SyncRecorder<InboundRequest>()
        let outcome = try await session.run(
            [.text("Prepare a read-only plan.")],
            onUpdate: { updates.append($0) },
            onClientOperation: { operations.append($0) },
            onInboundRequest: { inboundRequests.append($0) })

        await connection.endSubscription(subId)
        let connectionEvents = await eventOrderTask.value
        let stats = await connection.permissionStats(for: session.id)
        await connection.close()
        await serverPeer.close()
        return SyntheticTurnResult(
            outcome: outcome, updates: updates.values, operations: operations.values,
            inboundRequests: inboundRequests.values, permissionResponses: permissionReplies.values,
            connectionEvents: connectionEvents, permissionStats: stats, wireLines: wireLines.values)
    }

    private static func handleSyntheticAgentRequest(
        method: String,
        agentName: String,
        sessionId: SessionId,
        steps: [PromptWireStep],
        promptResultJSON: String,
        peer: JSONRPCPeer,
        permissionReplies: SyncRecorder<RequestPermissionResponse>
    ) async -> Result<JSONValue, JSONRPCErrorBody> {
        do {
            switch method {
            case "initialize":
                let reply = InitializeResponse(agentInfo: Implementation(name: agentName, version: "1.0"))
                return .success(try JSONValue(encoding: reply))
            case "session/new":
                return .success(try JSONValue(encoding: NewSessionResponse(sessionId: sessionId)))
            case "session/prompt":
                for step in steps {
                    switch step {
                    case .update(let paramsJSON):
                        let params = try JSONDecoder().decode(JSONValue.self, from: Data(paramsJSON.utf8))
                        try await peer.sendNotification(method: "session/update", params: params)
                    case .permissionRequest(let paramsJSON):
                        let params = try JSONDecoder().decode(JSONValue.self, from: Data(paramsJSON.utf8))
                        let rawReply = try await peer.sendRequest(
                            method: "session/request_permission", params: params)
                        permissionReplies.append(try rawReply.decoded(RequestPermissionResponse.self))
                    }
                }
                let result = try JSONDecoder().decode(JSONValue.self, from: Data(promptResultJSON.utf8))
                return .success(result)
            default:
                return .failure(.methodNotFound(method))
            }
        } catch let error as JSONRPCErrorBody {
            return .failure(error)
        } catch {
            return .failure(.internalError(error.localizedDescription))
        }
    }

    private static func eventLabel(_ event: ConnectionEvent) -> String {
        switch event {
        case .update(let note): return "update:\(note.update.kind)"
        case .clientOperation(let op): return "clientOp:\(op.method)"
        case .inboundRequest(let req): return "inbound:\(req.method)"
        case .promptAnswered(_, let response): return "answered:\(response.stopReason.rawValue)"
        case .promptFailed(_, let error): return "failed:\(error.code)"
        }
    }

    /// Synthetic wire steps reconstructing the reported sequence of background run
    /// `93DBBF66-36BA-4AF3-8273-A3BA1F2E59F9` (two thought chunks, usage update, tool events,
    /// zero message chunks). Marked synthetic because no raw wire transcript is attached to #343/#346.
    private static func syntheticBackground93DBBF66Steps(sessionId: SessionId) -> [PromptWireStep] {
        [
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"agent_thought_chunk",
                "content":{"type":"text","text":"First synthetic thought chunk."}}}
                """),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"agent_thought_chunk",
                "content":{"type":"text","text":"Second synthetic thought chunk reviewing tools."}}}
                """),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"usage_update",
                "used":27745,"size":1048576}}
                """),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"tool_call",
                "toolCallId":"call-mcp-1","name":"mcp_missioncontrol_view_issue",
                "args":{"number":277,"repo":"Cocoanetics/SwiftPorts"},
                "title":"Run mcp_missioncontrol_view_issue","kind":"other","status":"in_progress",
                "rawInput":{"number":277,"repo":"Cocoanetics/SwiftPorts"}}}
                """),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"tool_call_update",
                "toolCallId":"call-mcp-1","status":"completed",
                "rawOutput":{"state":"open"}}}
                """),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"tool_call",
                "toolCallId":"call-exec-1","name":"run_command",
                "args":{"CommandLine":"git rev-parse HEAD"},
                "title":"git rev-parse HEAD","kind":"execute","status":"in_progress",
                "rawInput":{"CommandLine":"git rev-parse HEAD"}}}
                """),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"tool_call_update",
                "toolCallId":"call-exec-1","status":"completed",
                "rawOutput":{"stdout":"abc123"}}}
                """)
        ]
    }

    // MARK: - Synthetic replay of background run 93DBBF66-36BA-4AF3-8273-A3BA1F2E59F9

    /// Synthetic replay of the thought-only `end_turn` trace reported for background run
    /// `93DBBF66-36BA-4AF3-8273-A3BA1F2E59F9`: two `agent_thought_chunk` updates, tool events,
    /// zero `agent_message_chunk` updates, and `{"stopReason":"end_turn"}`.
    @Test func syntheticThoughtOnlyEndTurnYieldsEmptyTextAndNoInferredMetadata() async throws {
        let sessionId = "bg-93dbbf66-synthetic"
        let run = try await Self.runSyntheticTurn(
            sessionId: sessionId,
            steps: Self.syntheticBackground93DBBF66Steps(sessionId: sessionId),
            promptResultJSON: #"{"stopReason":"end_turn"}"#)

        // Message-only collection preserved: no final report synthesized from thoughts.
        #expect(run.outcome.text.isEmpty)
        #expect(run.outcome.stopReason == .endTurn)
        #expect(run.outcome.usage == nil)
        #expect(run.outcome.meta == nil)
        #expect(run.outcome.sessionFailure == nil)
        #expect(run.outcome.clientOperations.isEmpty)
        #expect(run.operations.isEmpty)

        // Throwing helper must not invent a SessionFailure for an empty end_turn.
        let terminalResponse = PromptResponse(
            stopReason: run.outcome.stopReason, usage: run.outcome.usage, meta: run.outcome.meta)
        #expect(terminalResponse.sessionFailure == nil)
        #expect(try terminalResponse.throwingSessionFailure().stopReason == .endTurn)

        // Thoughts remained thoughts, message chunks stayed zero, and tool identity survived.
        let thoughtTexts = run.updates.compactMap { update -> String? in
            if case .agentThoughtChunk(let block) = update { return block.text }
            return nil
        }
        let messageTexts = run.updates.compactMap { update -> String? in
            if case .agentMessageChunk(let block) = update { return block.text }
            return nil
        }
        #expect(thoughtTexts == [
            "First synthetic thought chunk.",
            "Second synthetic thought chunk reviewing tools."
        ])
        #expect(messageTexts.isEmpty)
        #expect(run.updates.map(\.kind) == [
            "agent_thought_chunk", "agent_thought_chunk", "usage_update",
            "tool_call", "tool_call_update", "tool_call", "tool_call_update"
        ])
        if case .toolCall(let mcpCall) = run.updates[3] {
            #expect(mcpCall.name == "mcp_missioncontrol_view_issue")
            #expect(mcpCall.args == .object([
                "number": .integer(277), "repo": .string("Cocoanetics/SwiftPorts")
            ]))
        } else {
            Issue.record("Expected MCP tool_call at index 3, got \(run.updates[3])")
        }
        if case .toolCall(let execCall) = run.updates[5] {
            #expect(execCall.name == "run_command")
            #expect(execCall.rawInput == .object(["CommandLine": .string("git rev-parse HEAD")]))
        } else {
            Issue.record("Expected execute tool_call at index 5, got \(run.updates[5])")
        }

        // Wire order places all updates strictly before the prompt answer.
        #expect(run.connectionEvents == [
            "update:agent_thought_chunk", "update:agent_thought_chunk", "update:usage_update",
            "update:tool_call", "update:tool_call_update", "update:tool_call", "update:tool_call_update",
            "answered:end_turn"
        ])

        // Replaying the recorded wire NDJSON through ACPEventLogReader preserves the same shape.
        let ndjson = Data((run.wireLines.joined(separator: "\n") + "\n").utf8)
        let replayed = ACPEventLogReader.entries(in: ndjson)
        let replayedUpdates = replayed.compactMap { entry -> SessionUpdate? in
            if case .update(let note) = entry { return note.update }
            return nil
        }
        let replayedResponses = replayed.compactMap { entry -> PromptResponse? in
            if case .promptResponse(_, let response) = entry { return response }
            return nil
        }
        #expect(replayedUpdates.map(\.kind) == run.updates.map(\.kind))
        let replayedTerminal = try #require(replayedResponses.first)
        #expect(replayedResponses.count == 1)
        #expect(replayedTerminal.stopReason == .endTurn)
        #expect(replayedTerminal.usage == nil)
        #expect(replayedTerminal.meta == nil)
        #expect(replayedTerminal.sessionFailure == nil)
    }

    /// Synthetic thought-only `end_turn` that also supplies genuine terminal `usage` (including
    /// `thought_tokens`) and `_meta`: both are preserved intact while `outcome.text` stays empty
    /// and no `SessionFailure` is inferred.
    @Test func syntheticThoughtOnlyEndTurnPreservesSuppliedUsageAndMeta() async throws {
        let sessionId = "bg-93dbbf66-meta-synthetic"
        let promptResult = #"""
            {"stopReason":"end_turn",
            "usage":{"input_tokens":26726,"output_tokens":1019,"thought_tokens":571,"total_tokens":27745},
            "_meta":{"provider":{"trace":"synthetic-thought-only"}}}
            """#
        let run = try await Self.runSyntheticTurn(
            sessionId: sessionId,
            steps: Self.syntheticBackground93DBBF66Steps(sessionId: sessionId),
            promptResultJSON: promptResult)

        #expect(run.outcome.text.isEmpty)
        #expect(run.outcome.stopReason == .endTurn)
        #expect(run.outcome.usage?.inputTokens == 26_726)
        #expect(run.outcome.usage?.outputTokens == 1019)
        #expect(run.outcome.usage?.thoughtTokens == 571)
        #expect(run.outcome.usage?.totalTokens == 27_745)
        #expect(run.outcome.meta == .object([
            "provider": .object(["trace": .string("synthetic-thought-only")])
        ]))
        #expect(run.outcome.sessionFailure == nil)
        #expect(run.outcome.clientOperations.isEmpty)
    }

    // MARK: - Mixed thought/message turn

    /// Synthetic turn mixing thoughts, tool updates, and message chunks: `outcome.text` collects
    /// strictly `agent_message_chunk` text while `onUpdate` delivers every event in wire order.
    @Test func syntheticMixedThoughtAndMessageTurnCollectsOnlyMessageChunks() async throws {
        let sessionId = "mixed-synthetic"
        let steps: [PromptWireStep] = [
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"agent_thought_chunk",
                "content":{"type":"text","text":"Hidden reasoning 1."}}}
                """),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"agent_message_chunk",
                "content":{"type":"text","text":"Final "}}}
                """),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"tool_call",
                "toolCallId":"call-read-1","name":"read_file","args":{"path":"Package.swift"},
                "title":"File Package.swift","kind":"read","status":"completed"}}
                """),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"agent_thought_chunk",
                "content":{"type":"text","text":"Hidden reasoning 2."}}}
                """),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"agent_message_chunk",
                "content":{"type":"text","text":"report."}}}
                """)
        ]

        let run = try await Self.runSyntheticTurn(
            sessionId: sessionId, steps: steps, promptResultJSON: #"{"stopReason":"end_turn"}"#)

        #expect(run.outcome.text == "Final report.")
        #expect(run.outcome.stopReason == .endTurn)
        #expect(run.outcome.sessionFailure == nil)
        #expect(run.updates.map(\.kind) == [
            "agent_thought_chunk", "agent_message_chunk", "tool_call",
            "agent_thought_chunk", "agent_message_chunk"
        ])
        let thoughts = run.updates.compactMap { update -> String? in
            if case .agentThoughtChunk(let block) = update { return block.text }
            return nil
        }
        #expect(thoughts == ["Hidden reasoning 1.", "Hidden reasoning 2."])
    }

    // MARK: - Explicit cancelled and unknown stop reasons

    /// Synthetic turns ending with explicit `cancelled` and an unknown adapter `stopReason`:
    /// stop reasons, `usage`, and `_meta` are preserved verbatim without synthesizing text,
    /// cancellation reasons, client operations, or `SessionFailure`.
    @Test func syntheticExplicitCancelledAndUnknownStopReasonsPreserveMetadata() async throws {
        let cancelSession = "cancel-synthetic"
        let cancelSteps: [PromptWireStep] = [
            .update("""
                {"sessionId":"\(cancelSession)","update":{"sessionUpdate":"agent_thought_chunk",
                "content":{"type":"text","text":"Reasoning before cancellation."}}}
                """)
        ]
        let cancelResult = #"""
            {"stopReason":"cancelled",
            "usage":{"inputTokens":42,"outputTokens":0,"thoughtTokens":19,"totalTokens":61},
            "_meta":{"source":"synthetic-cancelled"}}
            """#
        let cancelled = try await Self.runSyntheticTurn(
            sessionId: cancelSession, steps: cancelSteps, promptResultJSON: cancelResult)

        #expect(cancelled.outcome.stopReason == .cancelled)
        #expect(cancelled.outcome.text.isEmpty)
        #expect(cancelled.outcome.usage?.inputTokens == 42)
        #expect(cancelled.outcome.usage?.thoughtTokens == 19)
        #expect(cancelled.outcome.meta == .object(["source": .string("synthetic-cancelled")]))
        #expect(cancelled.outcome.sessionFailure == nil)
        #expect(cancelled.outcome.clientOperations.isEmpty)
        #expect(cancelled.connectionEvents == ["update:agent_thought_chunk", "answered:cancelled"])

        let unknownSession = "unknown-stop-synthetic"
        let unknownSteps: [PromptWireStep] = [
            .update("""
                {"sessionId":"\(unknownSession)","update":{"sessionUpdate":"agent_thought_chunk",
                "content":{"type":"text","text":"Reasoning before unknown stop reason."}}}
                """)
        ]
        let unknownResult = #"""
            {"stopReason":"adapter_custom_stop","_meta":{"vendor":"synthetic-unknown"}}
            """#
        let unknown = try await Self.runSyntheticTurn(
            sessionId: unknownSession, steps: unknownSteps, promptResultJSON: unknownResult)

        #expect(unknown.outcome.stopReason == StopReason(rawValue: "adapter_custom_stop"))
        #expect(unknown.outcome.stopReason.rawValue == "adapter_custom_stop")
        #expect(unknown.outcome.text.isEmpty)
        #expect(unknown.outcome.usage == nil)
        #expect(unknown.outcome.meta == .object(["vendor": .string("synthetic-unknown")]))
        #expect(unknown.outcome.sessionFailure == nil)
        #expect(unknown.outcome.clientOperations.isEmpty)
        #expect(unknown.connectionEvents == ["update:agent_thought_chunk", "answered:adapter_custom_stop"])
    }

    // MARK: - Independent preservation of terminal _meta/usage, permission outcome, and notices

    /// Synthetic turn combining a thought-only `end_turn` carrying terminal `_meta` and `usage`
    /// with an Antigravity interaction question carrying `name` and `args`:
    /// - permission outcome is `.cancelled` with `_meta.acpx.permissionNotice`;
    /// - client-operation notice is ordered strictly before the agent's post-answer update;
    /// - terminal `PromptOutcome.meta` and `PromptOutcome.usage` stay untouched and independent.
    @Test func syntheticPermissionNoticeAndTerminalMetadataRemainIndependentAndWireOrdered() async throws {
        let sessionId = "independence-synthetic"
        let interactionPermission = """
            {"sessionId":"\(sessionId)",
            "toolCall":{"toolCallId":"interaction_101","name":"ask_user_question",
            "args":{"question":"Proceed?"},"title":"Proceed?","kind":"other",
            "rawInput":{"question":"Proceed?"}},
            "options":[{"optionId":"yes","name":"Yes","kind":"allow_once"},
            {"optionId":"no","name":"No","kind":"allow_once"}]}
            """
        let steps: [PromptWireStep] = [
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"agent_thought_chunk",
                "content":{"type":"text","text":"Thought before question."}}}
                """),
            .permissionRequest(interactionPermission),
            .update("""
                {"sessionId":"\(sessionId)","update":{"sessionUpdate":"agent_thought_chunk",
                "content":{"type":"text","text":"Thought after cancelled question."}}}
                """)
        ]
        let terminalJSON = #"""
            {"stopReason":"end_turn",
            "usage":{"inputTokens":100,"outputTokens":0,"thoughtTokens":25,"totalTokens":125},
            "_meta":{"adapter":{"terminal":true}}}
            """#

        let run = try await Self.runSyntheticTurn(
            sessionId: sessionId, steps: steps, promptResultJSON: terminalJSON, policy: .approveAll)

        // Permission reply itself carried `.cancelled` + `_meta.acpx.permissionNotice`.
        let permissionReply = try #require(run.permissionResponses.first)
        #expect(run.permissionResponses.count == 1)
        #expect(permissionReply.outcome == .cancelled)
        #expect(permissionReply.permissionNotice == AntigravityCompat.questionNotice)
        #expect(run.permissionStats.requested == 1)
        #expect(run.permissionStats.cancelled == 1)
        #expect(run.permissionStats.approved == 0)
        #expect(run.permissionStats.denied == 0)

        // Client-operation notice arrived before the agent's post-answer update and prompt answer.
        #expect(run.connectionEvents == [
            "update:agent_thought_chunk",
            "inbound:session/request_permission",
            "clientOp:session/request_permission",
            "update:agent_thought_chunk",
            "answered:end_turn"
        ])
        #expect(run.outcome.clientOperations.count == 1)
        #expect(run.outcome.clientOperations.first?.summary == AntigravityCompat.questionNotice)
        #expect(run.operations.count == 1)
        #expect(run.inboundRequests.map(\.method) == ["session/request_permission"])

        // Terminal response metadata and usage remain strictly independent from permission notices.
        #expect(run.outcome.text.isEmpty)
        #expect(run.outcome.stopReason == .endTurn)
        #expect(run.outcome.usage?.inputTokens == 100)
        #expect(run.outcome.usage?.outputTokens == 0)
        #expect(run.outcome.usage?.thoughtTokens == 25)
        #expect(run.outcome.usage?.totalTokens == 125)
        #expect(run.outcome.meta == .object(["adapter": .object(["terminal": .bool(true)])]))
        #expect(run.outcome.meta?["acpx"] == nil)
        #expect(run.outcome.sessionFailure == nil)
    }
}
