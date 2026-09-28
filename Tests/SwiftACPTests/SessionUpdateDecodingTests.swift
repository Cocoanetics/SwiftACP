import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// Session updates are read as the ACP SDK reads them, where its schema is lenient (#175):
/// a member that doesn't fit is left out, a list keeps the entries that fit, and only a
/// required member fails the update. A kind or status SwiftACP doesn't know is still kept,
/// as is a content entry of a type it doesn't know: the SDK drops those.
struct SessionUpdateDecodingTests {
    private func decode(_ json: String) throws -> SessionUpdate {
        try JSONDecoder().decode(SessionUpdate.self, from: Data(json.utf8))
    }

    private func toolCall(_ json: String) throws -> ToolCall {
        guard case .toolCall(let call) = try decode(json) else { throw POSIXError(.EINVAL) }
        return call
    }

    /// A `kind` or `status` that doesn't fit is left out, and so are the `content` and
    /// `locations` entries that don't: a location's line that is no line number goes, and
    /// the location stays. An entry that fits loses only its optional members that don't,
    /// such as a diff's `oldText` or a block's `annotations`.
    @Test func aToolCallsMembersThatDontFitAreLeftOut() throws {
        let call = try toolCall(#"""
            {"sessionUpdate":"tool_call","toolCallId":"t1","title":"Run","kind":5,"status":{"x":1},
            "content":[{"type":"content","content":{"type":"text","text":"ok"}},
            {"type":"content","content":{"type":"text"}},{"type":"diff","path":"/a","newText":"n"},
            {"type":"diff","path":"/b"},{"type":"diff","path":"/c","oldText":5,"newText":"m"},
            {"type":"content","content":{"type":"text","text":"noted","annotations":"x"}},
            {"type":"terminal"},7,{"type":5},{"type":"bogus"}],
            "locations":[{"path":"/a","line":3},{"path":"/b","line":-1},{"path":"/c","line":"x"},{"line":1},"x"]}
            """#)
        #expect(call.kind == nil)
        #expect(call.status == nil)
        let content = try #require(call.content)
        #expect(content.count == 5)
        if case .content(let block) = content[0] { #expect(block.text == "ok") } else { Issue.record("\(content[0])") }
        if case .diff(let diff) = content[1] { #expect(diff.path == "/a") } else { Issue.record("\(content[1])") }
        if case .diff(let diff) = content[2] {
            #expect(diff == ToolCallContent.Diff(path: "/c", newText: "m"))
        } else {
            Issue.record("\(content[2])")
        }
        if case .content(let block) = content[3] {
            #expect(block.text == "noted")
        } else {
            Issue.record("\(content[3])")
        }
        if case .other = content[4] {} else { Issue.record("\(content[4])") }
        #expect(call.locations == [
            ToolCallLocation(path: "/a", line: 3), ToolCallLocation(path: "/b"), ToolCallLocation(path: "/c")
        ])
    }

    /// A tool call's `content` or `locations` that is no list is empty; one left out is none.
    @Test func aToolCallsListThatIsNoListIsEmpty() throws {
        let call = try toolCall(
            #"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Run","content":"x","locations":null}"#)
        #expect(call.content?.isEmpty == true)
        #expect(call.locations?.isEmpty == true)
        let plain = try toolCall(#"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Run"}"#)
        #expect(plain.content == nil)
        #expect(plain.locations == nil)
    }

    /// A tool call without its id or title, or with one that is no string, is no tool call: it
    /// comes as `.other`, as it was sent, for acpx's formatter shows it though its SDK refuses it
    /// (#175).
    @Test func aToolCallNeedsItsIdAndTitle() throws {
        for json in [
            #"{"sessionUpdate":"tool_call","title":"Run"}"#, #"{"sessionUpdate":"tool_call","toolCallId":"t1"}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":5,"title":"Run"}"#
        ] {
            guard case .other("tool_call", let payload) = try decode(json) else {
                Issue.record("\(json) was read as a tool call")
                continue
            }
            #expect(payload == (try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))))
        }
    }

    /// A tool call's members sent as `null` are known as such, and go on as `null` — through
    /// acpxd's relay to the CLI too — as a tool update's do (#270 review).
    @Test func aToolCallKeepsItsNullMembers() throws {
        let json = #"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Run","kind":null,"status":null,"#
            + #""rawInput":null,"rawOutput":{"a":1}}"#
        guard case .toolCall(let call) = try decode(json) else { throw POSIXError(.EINVAL) }
        #expect(call.nullMembers == ["kind", "status", "rawInput"])
        let relayed = try JSONEncoder().encode(SessionUpdate.toolCall(call))
        guard case .toolCall(let again) = try JSONDecoder().decode(SessionUpdate.self, from: relayed) else {
            throw POSIXError(.EINVAL)
        }
        #expect(again.nullMembers == ["kind", "status", "rawInput"])
        #expect(again.rawOutput == .object(["a": .integer(1)]))
    }

    /// An update's member that doesn't fit is left out, as if it were not sent: not taken
    /// as `null`, which clears what an earlier update set.
    @Test func aToolCallUpdatesMembersThatDontFitAreLeftOut() throws {
        guard case .toolCallUpdate(let update) = try decode(#"""
            {"sessionUpdate":"tool_call_update","toolCallId":"t1","title":5,"kind":null,"status":3,
            "content":"x","locations":[{"path":"/a"},{"line":1}]}
            """#) else { throw POSIXError(.EINVAL) }
        #expect(update.title == nil)
        #expect(update.kind == nil)
        #expect(update.status == nil)
        #expect(update.content == nil)
        #expect(update.locations == [ToolCallLocation(path: "/a")])
        #expect(update.nullMembers == ["kind"])
        let unnamed = #"{"sessionUpdate":"tool_call_update","status":"completed"}"#
        guard case .other("tool_call_update", _) = try decode(unnamed) else {
            Issue.record("an update without its tool's id was read as one")
            return
        }
    }

    /// Commands and a plan's entries: the update fails without the list, the list is empty
    /// when it is no list, and it keeps the entries that fit.
    @Test func listsAnUpdateNeedsAreReadLeniently() throws {
        guard case .availableCommandsUpdate(let commands) = try decode(#"""
            {"sessionUpdate":"available_commands_update","availableCommands":[{"name":"a","description":"A"},
            {"name":5},"bare"]}
            """#) else { throw POSIXError(.EINVAL) }
        #expect(commands.map(\.name) == ["a", "bare"])
        guard case .availableCommandsUpdate(let none) = try decode(
            #"{"sessionUpdate":"available_commands_update","availableCommands":{}}"#) else { throw POSIXError(.EINVAL) }
        #expect(none.isEmpty)
        guard case .plan(let entries) = try decode(#"""
            {"sessionUpdate":"plan","entries":[{"content":"one","priority":"high","status":"pending"},{"content":2},
            {"content":"three","priority":1}]}
            """#) else { throw POSIXError(.EINVAL) }
        #expect(entries.map(\.content) == ["one"])
        guard case .plan(let noEntries) = try decode(#"{"sessionUpdate":"plan","entries":null}"#) else {
            throw POSIXError(.EINVAL)
        }
        #expect(noEntries.isEmpty)
        for json in [#"{"sessionUpdate":"available_commands_update"}"#, #"{"sessionUpdate":"plan"}"#] {
            #expect(throws: DecodingError.self, "\(json)") { try decode(json) }
        }
    }
}
