import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Locks down the hand-written Codable logic for the internally-tagged unions
/// (content blocks, session updates, permission outcomes) and the `_meta` keys.
struct CodableTests {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(T.self, from: Data(json.utf8))
    }

    private func encodedString<T: Encodable>(_ value: T) throws -> String {
        String(data: try encoder.encode(value), encoding: .utf8)!
    }

    // MARK: Content blocks

    @Test func textContentRoundTrip() throws {
        let block = try decode(ContentBlock.self, #"{"type":"text","text":"hi"}"#)
        #expect(block.text == "hi")
        let again = try decode(ContentBlock.self, encodedString(block))
        #expect(again.text == "hi")
    }

    @Test func imageContentDecodes() throws {
        let block = try decode(
            ContentBlock.self, #"{"type":"image","data":"AAAA","mimeType":"image/png"}"#)
        guard case .image(let image) = block else { Issue.record("expected image"); return }
        #expect(image.mimeType == "image/png")
        #expect(image.data == "AAAA")
    }

    @Test func resourceLinkDecodes() throws {
        let block = try decode(
            ContentBlock.self,
            #"{"type":"resource_link","uri":"file:///a","name":"a","size":12}"#)
        guard case .resourceLink(let link) = block else { Issue.record("expected resource_link"); return }
        #expect(link.uri == "file:///a")
        #expect(link.size == 12)
    }

    // MARK: Session updates

    @Test func agentMessageChunkDecodes() throws {
        let update = try decode(
            SessionUpdate.self,
            #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"yo"}}"#)
        guard case .agentMessageChunk(let block) = update else { Issue.record("expected chunk"); return }
        #expect(block.text == "yo")
        #expect(update.kind == "agent_message_chunk")
    }

    @Test func toolCallDecodesInlineFields() throws {
        let update = try decode(
            SessionUpdate.self,
            #"{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Read file","kind":"read","status":"pending"}"#)
        guard case .toolCall(let call) = update else { Issue.record("expected tool_call"); return }
        #expect(call.toolCallId == "c1")
        #expect(call.title == "Read file")
        #expect(call.kind == .read)
        #expect(call.status == .pending)
    }

    @Test func planDecodes() throws {
        let update = try decode(
            SessionUpdate.self,
            #"{"sessionUpdate":"plan","entries":[{"content":"step","status":"in_progress","priority":"high"}]}"#)
        guard case .plan(let entries) = update else { Issue.record("expected plan"); return }
        #expect(entries.first?.content == "step")
        #expect(entries.first?.status == .inProgress)
    }

    @Test func usageUpdateDecodes() throws {
        let update = try decode(
            SessionUpdate.self,
            #"{"sessionUpdate":"usage_update","used":1200,"size":200000,"#
                + #""cost":{"amount":0.0123,"currency":"USD"},"_meta":{"usage":{"inputTokens":800}}}"#)
        guard case .usageUpdate(let usage) = update else { Issue.record("expected usage_update"); return }
        #expect(usage.used == 1200)
        #expect(usage.size == 200_000)
        #expect(usage.cost?.amount == 0.0123)
        #expect(update.kind == "usage_update")
    }

    @Test func unknownSessionUpdatePreserved() throws {
        let update = try decode(SessionUpdate.self, #"{"sessionUpdate":"future_thing","extra":42}"#)
        guard case .other(let kind, _) = update else { Issue.record("expected other"); return }
        #expect(kind == "future_thing")
    }

    @Test func sessionNotificationDecodes() throws {
        let note = try decode(
            SessionNotification.self,
            #"{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","#
                + #""content":{"type":"text","text":"x"}}}"#)
        #expect(note.sessionId == "s1")
        #expect(note.update.kind == "agent_message_chunk")
    }

    // MARK: Tool-call content

    @Test func toolCallContentDiff() throws {
        let content = try decode(
            ToolCallContent.self, #"{"type":"diff","path":"/a.txt","oldText":"a","newText":"b"}"#)
        guard case .diff(let diff) = content else { Issue.record("expected diff"); return }
        #expect(diff.path == "/a.txt")
        #expect(diff.newText == "b")
    }

    // MARK: Permission

    @Test func permissionOutcomeSelectedRoundTrip() throws {
        let outcome = RequestPermissionOutcome.selected(optionId: "opt-1")
        let decoded = try decode(RequestPermissionOutcome.self, encodedString(outcome))
        guard case .selected(let id) = decoded else { Issue.record("expected selected"); return }
        #expect(id == "opt-1")
    }

    @Test func permissionOutcomeCancelledRoundTrip() throws {
        let decoded = try decode(
            RequestPermissionOutcome.self, encodedString(RequestPermissionOutcome.cancelled))
        guard case .cancelled = decoded else { Issue.record("expected cancelled"); return }
    }

    // MARK: Open enums

    @Test func openEnumDecodesUnknownValue() throws {
        let reason = try decode(StopReason.self, "\"some_future_reason\"")
        #expect(reason.rawValue == "some_future_reason")
        #expect(reason != .endTurn)
    }

    // MARK: _meta keys and omitted optionals

    @Test func newSessionRequestUsesMetaKey() throws {
        let request = NewSessionRequest(cwd: "/tmp", meta: .object(["k": .string("v")]))
        let json = try encodedString(request)
        #expect(json.contains("\"_meta\""))
        #expect(!json.contains("\"meta\""))
    }

    @Test func initializeRequestOmitsNilClientInfo() throws {
        let request = InitializeRequest(clientCapabilities: .headlessController)
        let json = try encodedString(request)
        #expect(!json.contains("clientInfo"))
        #expect(json.contains("\"protocolVersion\":1"))
    }

    // MARK: JSON-RPC error formatting

    @Test func jsonrpcErrorDescriptionIncludesStructuredData() {
        let error = JSONRPCErrorBody(
            code: -32603, message: "Internal error",
            data: .object(["errorKind": .string("rate_limit")]))
        let description = error.errorDescription ?? ""
        #expect(description.contains("-32603"))
        #expect(description.contains("Internal error"))
        #expect(description.contains("rate_limit")) // structured detail must surface
    }

    @Test func jsonrpcErrorDescriptionWithoutData() {
        let error = JSONRPCErrorBody(code: -32600, message: "Invalid Request")
        #expect(error.errorDescription == "JSON-RPC error -32600: Invalid Request")
    }

    @Test func mcpServerStdioRoundTrip() throws {
        let server = MCPServerSpec.stdio(StdioMCPServer(name: "fs", command: "node", args: ["s.js"]))
        let decoded = try decode(MCPServerSpec.self, encodedString(server))
        guard case .stdio(let stdio) = decoded else { Issue.record("expected stdio"); return }
        #expect(stdio.command == "node")
        #expect(stdio.args == ["s.js"])
    }

    // MARK: Daemon terminal event (stop reason as a streamed event)

    @Test func turnEndedEventRoundTrips() throws {
        let event = TurnEndedEvent(stopReason: "end_turn")
        let json = try encodedString(event)
        #expect(json.contains("\"stopReason\":\"end_turn\""))
        let decoded = try decode(TurnEndedEvent.self, json)
        #expect(decoded.stopReason == "end_turn")
    }

    // The CLI's log handler decodes each notification as TurnEndedEvent first, then
    // falls back to SessionNotification. These two locks keep that dispatch
    // unambiguous: the shapes must be mutually undecodable.
    @Test func turnEndedEventIsNotASessionNotification() {
        #expect((try? decode(SessionNotification.self, #"{"stopReason":"refusal"}"#)) == nil)
    }

    @Test func sessionNotificationIsNotATurnEndedEvent() {
        let note =
            #"{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"x"}}}"#
        #expect((try? decode(TurnEndedEvent.self, note)) == nil)
    }
}
