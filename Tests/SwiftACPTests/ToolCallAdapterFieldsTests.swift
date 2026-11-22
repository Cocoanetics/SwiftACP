import Foundation
import JSONFoundation
import JSONRPCPeer
@testable import SwiftACP
import Testing

/// End-to-end regressions for preserving opaque adapter-provided `name` and `args`
/// across `ToolCall`, `ToolCallUpdate`, `SessionUpdate` relay, and `session/request_permission`
/// dispatch (#344, part of #343).
@Suite(.timeLimit(.minutes(1)))
struct ToolCallAdapterFieldsTests {
    private actor CapturedPermissions {
        private(set) var requests: [RequestPermissionRequest] = []
        func record(_ request: RequestPermissionRequest) { requests.append(request) }
    }

    /// Minimal raw JSON-RPC agent peer on the server end of a `LoopbackTransport`, so tests
    /// can send exact wire-JSON `session/request_permission` payloads without going through
    /// `ToolCallUpdate`'s encoder first.
    private static func runRawPermissionWire(
        agentName: String,
        permissionWireJSON: String,
        policy: PermissionPolicy
    ) async throws -> (response: RequestPermissionResponse, operations: [ClientOperation]) {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let serverPeer = JSONRPCPeer(transport: serverTransport)
        await serverPeer.setHandlers(
            request: { method, _ in
                switch method {
                case "initialize":
                    let reply = InitializeResponse(agentInfo: Implementation(name: agentName, version: "1.0"))
                    return (try? JSONValue(encoding: reply)).map(Result.success)
                        ?? .failure(.internalError("encode initialize failed"))
                case "session/new":
                    let reply = NewSessionResponse(sessionId: "wire-session")
                    return (try? JSONValue(encoding: reply)).map(Result.success)
                        ?? .failure(.internalError("encode session/new failed"))
                default:
                    return .failure(.methodNotFound(method))
                }
            },
            notification: { _, _ in })
        await serverPeer.start()

        let client = ACPAgentConnection(
            transport: clientTransport,
            handlers: .standard(permission: policy, nonInteractivePermissions: .deny, terminal: .none))
        await client.start()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        _ = try await client.newSession(NewSessionRequest(cwd: "/tmp"))

        let (subscriptionId, stream) = await client.makeEventSubscription()
        let consumer = Task { () -> [ClientOperation] in
            var operations: [ClientOperation] = []
            for await event in stream {
                if case .clientOperation(let operation) = event {
                    operations.append(operation)
                }
            }
            return operations
        }

        let params = try JSONDecoder().decode(JSONValue.self, from: Data(permissionWireJSON.utf8))
        let rawResult = try await serverPeer.sendRequest(method: "session/request_permission", params: params)
        let response = try rawResult.decoded(RequestPermissionResponse.self)

        await client.endSubscription(subscriptionId)
        let operations = await consumer.value
        await client.close()
        await serverPeer.close()
        return (response, operations)
    }

    /// Regression for #344: the sanitized #343 `session/request_permission` wire reaches the
    /// real host callback on `ACPAgentConnection` with exact `name`, `args`, and `rawInput`.
    @Test func sanitized343PermissionWireReachesHostCallbackWithExactNameArgsAndRawInput() async throws {
        let wire = #"""
            {"sessionId":"wire-session",
            "toolCall":{"toolCallId":"call-example","name":"mcp_missioncontrol_view_issue",
            "args":{"number":277,"repo":"Cocoanetics/SwiftPorts"},
            "title":"Run mcp_missioncontrol_view_issue","kind":"other",
            "rawInput":{"number":277,"repo":"Cocoanetics/SwiftPorts"}},
            "options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},
            {"optionId":"deny","name":"Deny","kind":"reject_once"}]}
            """#
        let captured = CapturedPermissions()
        let (response, operations) = try await Self.runRawPermissionWire(
            agentName: AntigravityCompat.agentName,
            permissionWireJSON: wire,
            policy: .custom { request in
                await captured.record(request)
                return .selected("allow")
            })

        #expect(response.outcome == .selected(optionId: "allow"))
        #expect(operations.isEmpty)
        let received = try #require(await captured.requests.first)
        #expect(received.sessionId == "wire-session")
        #expect(received.toolCall.toolCallId == "call-example")
        #expect(received.toolCall.name == "mcp_missioncontrol_view_issue")
        #expect(received.toolCall.args == .object([
            "number": .integer(277), "repo": .string("Cocoanetics/SwiftPorts")
        ]))
        #expect(received.toolCall.title == "Run mcp_missioncontrol_view_issue")
        #expect(received.toolCall.kind == .other)
        #expect(received.toolCall.rawInput == .object([
            "number": .integer(277), "repo": .string("Cocoanetics/SwiftPorts")
        ]))
        #expect(received.toolCall.nullMembers.isEmpty)
        #expect(received.options.map(\.optionId) == ["allow", "deny"])
    }

    /// When `args` and `rawInput` disagree (including shell `rawInput.CommandLine`), both stay
    /// visible as separate values at the host callback; neither overwrites the other.
    @Test func conflictingArgsAndRawInputStaySeparateAtHostCallback() async throws {
        let wire = #"""
            {"sessionId":"wire-session",
            "toolCall":{"toolCallId":"call-shell","name":"run_command",
            "args":{"CommandLine":"rm -rf /tmp/fake","cwd":"/tmp"},
            "title":"Run shell command","kind":"execute",
            "rawInput":{"CommandLine":"git status"}},
            "options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},
            {"optionId":"deny","name":"Deny","kind":"reject_once"}]}
            """#
        let captured = CapturedPermissions()
        let (response, _) = try await Self.runRawPermissionWire(
            agentName: AntigravityCompat.agentName,
            permissionWireJSON: wire,
            policy: .custom { request in
                await captured.record(request)
                return .selected("deny")
            })

        #expect(response.outcome == .selected(optionId: "deny"))
        let toolCall = try #require(await captured.requests.first?.toolCall)
        #expect(toolCall.name == "run_command")
        #expect(toolCall.args == .object([
            "CommandLine": .string("rm -rf /tmp/fake"), "cwd": .string("/tmp")
        ]))
        #expect(toolCall.rawInput == .object(["CommandLine": .string("git status")]))
    }

    /// `name` is opaque and unauthenticated: built-in approval policy does not infer tool kind
    /// or grant approval from `name`.
    @Test func opaqueToolNameDoesNotAlterApprovalPolicy() async throws {
        let wire = #"""
            {"sessionId":"wire-session",
            "toolCall":{"toolCallId":"call-opaque","name":"read_file",
            "args":{"path":"README.md"},
            "title":"Run mcp_missioncontrol_view_issue","kind":"other",
            "rawInput":{"path":"README.md"}},
            "options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},
            {"optionId":"deny","name":"Deny","kind":"reject_once"}]}
            """#
        let (response, _) = try await Self.runRawPermissionWire(
            agentName: AntigravityCompat.agentName,
            permissionWireJSON: wire,
            policy: .approveReads)
        #expect(response.outcome == .selected(optionId: "deny"))

        let untitled = RequestPermissionRequest(
            sessionId: "s",
            toolCall: ToolCallUpdate(
                toolCallId: "t1", title: nil, kind: nil, name: "read_file",
                args: .object(["path": .string("a.txt")])),
            options: [PermissionOption(optionId: "allow", name: "Allow", kind: .allowOnce)])
        #expect(ToolPermissionApproval.inferredKind(of: untitled) == nil)
    }

    /// Antigravity interaction questions carrying `name` and `args` are still cancelled ahead
    /// of every policy and custom host callback; other providers' `interaction_*` requests
    /// still reach the callback with exact `name` and `args`.
    @Test func antigravityInteractionQuestionWithNameAndArgsIsStillCancelled() async throws {
        let wire = #"""
            {"sessionId":"wire-session",
            "toolCall":{"toolCallId":"interaction_99","name":"ask_user_question",
            "args":{"question":"Continue?"},"title":"Which option?","kind":"other",
            "rawInput":{"question":"Continue?"}},
            "options":[{"optionId":"answer-a","name":"Yes","kind":"allow_once"},
            {"optionId":"answer-b","name":"No","kind":"allow_once"}]}
            """#

        for policy in [PermissionPolicy.approveAll, .approveReads, .denyAll] {
            let (response, operations) = try await Self.runRawPermissionWire(
                agentName: AntigravityCompat.agentName, permissionWireJSON: wire, policy: policy)
            #expect(response.outcome == .cancelled)
            #expect(response.permissionNotice == AntigravityCompat.questionNotice)
            #expect(operations.count == 1)
            #expect(operations.first?.summary == AntigravityCompat.questionNotice)
        }

        let antigravityCaptured = CapturedPermissions()
        let (customResponse, _) = try await Self.runRawPermissionWire(
            agentName: AntigravityCompat.agentName,
            permissionWireJSON: wire,
            policy: .custom { request in
                await antigravityCaptured.record(request)
                return .selected("answer-a")
            })
        #expect(customResponse.outcome == .cancelled)
        #expect(await antigravityCaptured.requests.isEmpty)

        // Another adapter's `interaction_*` id is opaque and reaches the host handler intact.
        let otherCaptured = CapturedPermissions()
        let (otherResponse, otherOps) = try await Self.runRawPermissionWire(
            agentName: "some-other-acp",
            permissionWireJSON: wire,
            policy: .custom { request in
                await otherCaptured.record(request)
                return .selected("answer-a")
            })
        #expect(otherResponse.outcome == .selected(optionId: "answer-a"))
        #expect(otherOps.isEmpty)
        let otherTool = try #require(await otherCaptured.requests.first?.toolCall)
        #expect(otherTool.name == "ask_user_question")
        #expect(otherTool.args == .object(["question": .string("Continue?")]))
    }

    /// `tool_call` and `tool_call_update` carrying `name`, `args`, `rawInput`, and `nullMembers`
    /// survive live loopback relay (`ACPServerSession` -> `ACPAgentConnection`) and event-log replay.
    @Test func toolCallAndUpdateSurviveLoopbackRelayAndEventLogReplay() async throws {
        struct RelayAgent: ACPAgentHandler {
            func initialize(_ request: InitializeRequest) async -> InitializeResponse {
                InitializeResponse(agentInfo: Implementation(name: AntigravityCompat.agentName, version: "1.0"))
            }

            func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
                NewSessionResponse(sessionId: "relay-session")
            }

            func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
                await session.sendToolCall(ToolCall(
                    toolCallId: "call-1", title: "Run mcp_missioncontrol_view_issue", kind: .other,
                    status: .inProgress, rawInput: .object(["source": .string("rawInput")]),
                    name: "mcp_missioncontrol_view_issue", args: .object(["source": .string("args")])))
                var clearingUpdate = ToolCallUpdate(
                    toolCallId: "call-1", status: .completed,
                    rawOutput: .object(["ok": .bool(true)]))
                clearingUpdate.nullMembers = ["name", "args"]
                await session.sendToolCallUpdate(clearingUpdate)
                return PromptResponse(stopReason: .endTurn)
            }
        }

        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: RelayAgent(), transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(transport: clientTransport)

        final class WireLines: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String] = []
            func append(_ line: String) { lock.withLock { storage.append(line) } }
            var lines: [String] { lock.withLock { storage } }
        }
        let wireLines = WireLines()
        await client.setWireObserver { line in wireLines.append(line) }
        await client.start()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))

        let (subscriptionId, stream) = await client.makeEventSubscription()
        let consumer = Task { () -> [SessionUpdate] in
            var updates: [SessionUpdate] = []
            for await event in stream {
                if case .update(let note) = event { updates.append(note.update) }
            }
            return updates
        }

        let reply = try await client.prompt(PromptRequest(sessionId: session.sessionId, prompt: [.text("go")]))
        #expect(reply.stopReason == .endTurn)
        await client.endSubscription(subscriptionId)
        let updates = await consumer.value
        await client.close()
        serverTask.cancel()

        #expect(updates.count == 2)
        guard case .toolCall(let call) = updates[0], case .toolCallUpdate(let update) = updates[1] else {
            Issue.record("Expected tool_call followed by tool_call_update, got \(updates)")
            return
        }
        #expect(call.name == "mcp_missioncontrol_view_issue")
        #expect(call.args == .object(["source": .string("args")]))
        #expect(call.rawInput == .object(["source": .string("rawInput")]))
        #expect(update.name == nil && update.args == nil)
        #expect(update.nullMembers == ["name", "args"])

        // Replay the same wire NDJSON through `ACPEventLogReader`.
        let ndjson = Data((wireLines.lines.joined(separator: "\n") + "\n").utf8)
        let replayedUpdates = ACPEventLogReader.entries(in: ndjson).compactMap { entry -> SessionUpdate? in
            if case .update(let note) = entry { return note.update }
            return nil
        }
        #expect(replayedUpdates.count == 2)
        if case .toolCall(let replayedCall) = replayedUpdates[0] {
            #expect(replayedCall.name == "mcp_missioncontrol_view_issue")
            #expect(replayedCall.args == .object(["source": .string("args")]))
            #expect(replayedCall.rawInput == .object(["source": .string("rawInput")]))
        } else {
            Issue.record("Missing replayed tool_call")
        }
        if case .toolCallUpdate(let replayedUpdate) = replayedUpdates[1] {
            #expect(replayedUpdate.name == nil && replayedUpdate.args == nil)
            #expect(replayedUpdate.nullMembers == ["name", "args"])
        } else {
            Issue.record("Missing replayed tool_call_update")
        }
    }
}
