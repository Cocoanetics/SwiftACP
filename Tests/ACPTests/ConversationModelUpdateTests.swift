@testable import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// The session updates acpx records besides the conversation's messages, and a user's
/// chunk, recorded as a prompt's block is (#122). What is expected is what acpx 0.19.1
/// recorded for the same updates, and for an image what 0.19.3 records (#88).
struct ConversationModelUpdateTests {
    private static func record() -> SessionRecord {
        let now = nowISO()
        return SessionRecord(
            acpxRecordId: "u-1", acpSessionId: "u-1", agentCommand: "agent", cwd: "/tmp", createdAt: now,
            lastUsedAt: now)
    }

    /// Apply the update `json`, read as it comes off the wire.
    private static func apply(_ json: String, to record: inout SessionRecord) throws {
        let update = try JSONDecoder().decode(SessionUpdate.self, from: Data(json.utf8))
        ConversationModel.recordSessionUpdate(
            into: &record, notification: SessionNotification(sessionId: "u-1", update: update))
    }

    /// The record as written.
    private static func written(_ record: SessionRecord) throws -> WireJSON {
        try #require(WireJSON(parsing: SessionRecordSerializer.data(for: record)))
    }

    /// Each command is trimmed, an empty description left out, and whether it takes input
    /// noted; a bare name, a command without a description, and a blank name are not kept.
    @Test func advertisedCommandsAreRecordedAsAcpxNormalizesThem() throws {
        var record = Self.record()
        try Self.apply(#"""
            {"sessionUpdate":"available_commands_update","availableCommands":[
            {"name":" plan ","description":" Plan it ","input":{"hint":"what"}},{"name":"go","description":"  "},
            {"name":"  ","description":"blank name"},"debug",{"name":"nodesc"},
            {"name":"badinput","description":"x","input":{"nohint":1}}]}
            """#, to: &record)
        #expect(try Self.written(record)["acpx"]?["available_commands"]?.stringified == """
            [{"name":"plan","description":"Plan it","has_input":true},{"name":"go","has_input":false},\
            {"name":"badinput","description":"x","has_input":false}]
            """)
    }

    /// No commands are recorded as none, though acpx's parser drops an empty list: for an
    /// empty list, one none of whose commands acpx keeps, and one that is no list, which
    /// acpx's ACP SDK reads as empty. An update without the list the SDK refuses.
    @Test func noCommandsAreRecordedAsNone() throws {
        for commands in ["[]", #"["bare",{"name":"nodesc"}]"#, #""x""#, "null"] {
            var record = Self.record()
            try Self.apply(
                #"{"sessionUpdate":"available_commands_update","availableCommands":\#(commands)}"#, to: &record)
            #expect(try Self.written(record)["acpx"]?["available_commands"]?.stringified == "[]", "\(commands)")
        }
        #expect(throws: DecodingError.self) {
            let update = #"{"sessionUpdate":"available_commands_update"}"#
            _ = try JSONDecoder().decode(SessionUpdate.self, from: Data(update.utf8))
        }
    }

    /// A title the agent gives is the conversation's; one that is no string clears it,
    /// as does `null`; an update without one leaves it.
    @Test func theTitleIsTheOneTheAgentGives() throws {
        var record = Self.record()
        try Self.apply(
            #"{"sessionUpdate":"session_info_update","title":"Named","updatedAt":"2020-01-01T00:00:00Z"}"#,
            to: &record)
        #expect(record.title == "Named")
        #expect(record.updatedAt != "2020-01-01T00:00:00Z")
        try Self.apply(#"{"sessionUpdate":"session_info_update"}"#, to: &record)
        #expect(record.title == "Named")
        try Self.apply(#"{"sessionUpdate":"session_info_update","title":5}"#, to: &record)
        #expect(record.title == nil)
        try Self.apply(#"{"sessionUpdate":"session_info_update","title":"Again"}"#, to: &record)
        try Self.apply(#"{"sessionUpdate":"session_info_update","title":null}"#, to: &record)
        #expect(try Self.written(record)["title"] == .null)
    }

    /// Config options the agent reports replace the session's, with the model state they
    /// carry.
    @Test func reportedConfigOptionsReplaceTheSessions() throws {
        var record = Self.record()
        try Self.apply(#"""
            {"sessionUpdate":"config_option_update","configOptions":[{"id":"model","name":"Model",
            "category":"model","type":"select","currentValue":"beta",
            "options":[{"value":"beta","name":"Beta"},{"value":"gamma","name":"Gamma"}]}]}
            """#, to: &record)
        let acpx = try #require(record.acpx)
        #expect(acpx.currentModelId == "beta")
        #expect(acpx.availableModels == ["beta", "gamma"])
        #expect(acpx.availableModelNames == ["beta": "Beta", "gamma": "Gamma"])
        #expect(acpx.modelControl == "config_option")
        guard case .array(let options)? = acpx.configOptions else { throw POSIXError(.EINVAL) }
        #expect(options.count == 1)
    }

    /// Reported options are recorded as acpx's ACP SDK reads them (`zSessionConfigOption`,
    /// #175): an option that doesn't fit is left out, and the others lose the members the
    /// schema doesn't know. Grouped options keep the options that fit, where one that
    /// doesn't fit fails a flat list, and with it the option.
    @Test func reportedConfigOptionsAreRecordedAsTheSDKReadsThem() throws {
        var record = Self.record()
        try Self.apply(#"""
            {"sessionUpdate":"config_option_update","configOptions":[
            {"id":"model","name":"Model","type":"select","currentValue":"a","extra":1,"description":null,
            "category":"model","_meta":"x","options":[{"value":"a","name":"A","junk":true,"description":5}]},
            {"id":"broken"},
            {"id":"flag","name":"Flag","type":"boolean","currentValue":true,"description":"On?","_meta":{"k":1}},
            {"id":"flag2","name":"Flag 2","type":"boolean","currentValue":"yes"},
            {"id":"grouped","name":"Grouped","type":"select","currentValue":"x","options":[
            {"group":"g","name":"G","options":[{"value":"x","name":"X"},{"value":1}]},
            {"group":"h","name":"H","options":"none"}]},
            {"id":"flat","name":"Flat","type":"select","currentValue":"x",
            "options":[{"value":"x","name":"X"},{"value":1}]}]}
            """#, to: &record)
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            [{"id":"model","name":"Model","type":"select","currentValue":"a","description":null,"category":"model",
            "options":[{"value":"a","name":"A"}]},
            {"id":"flag","name":"Flag","type":"boolean","currentValue":true,"description":"On?","_meta":{"k":1}},
            {"id":"grouped","name":"Grouped","type":"select","currentValue":"x","options":[
            {"group":"g","name":"G","options":[{"value":"x","name":"X"}]},{"group":"h","name":"H","options":[]}]}]
            """#.utf8))
        #expect(record.acpx?.configOptions == expected)
        #expect(record.acpx?.currentModelId == "a")
    }

    /// An update without options acpx's ACP SDK refuses, so the record stays as it was,
    /// not even stamped. Options that are no list are none.
    @Test func aConfigOptionUpdateWithoutOptionsLeavesTheRecord() throws {
        var record = Self.record()
        record.updatedAt = "2020-01-01T00:00:00.000Z"
        let update = try JSONDecoder().decode(
            SessionUpdate.self, from: Data(#"{"sessionUpdate":"config_option_update"}"#.utf8))
        #expect(!ConversationModel.recordSessionUpdate(
            into: &record, notification: SessionNotification(sessionId: "u-1", update: update)))
        if let acpx = record.acpx { Issue.record("\(acpx)") }
        #expect(record.updatedAt == "2020-01-01T00:00:00.000Z")
        try Self.apply(#"{"sessionUpdate":"config_option_update","configOptions":{"id":"x"}}"#, to: &record)
        #expect(record.acpx?.configOptions == .array([]))
    }

    /// Exec's control state takes reported options as the record does: an update without
    /// options changes nothing, and an option that doesn't fit is left out.
    @Test func theControlStateTakesReportedOptionsAsTheSDKReadsThem() throws {
        let control = ModelApplication.ControlState()
        func observe(_ update: String) throws {
            let message = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":\#(update)}}"#.utf8))
            control.observe(.inbound, message)
        }
        try observe(#"""
            {"sessionUpdate":"config_option_update","configOptions":[{"id":"model","name":"Model","type":"select",
            "currentValue":"a","options":[{"value":"a","name":"A"}]},{"id":"broken"}]}
            """#)
        #expect(control.state.currentModelId == "a")
        guard case .array(let options)? = control.state.configOptions else { throw POSIXError(.EINVAL) }
        #expect(options.count == 1)
        try observe(#"{"sessionUpdate":"config_option_update"}"#)
        guard case .array(let kept)? = control.state.configOptions else { throw POSIXError(.EINVAL) }
        #expect(kept.count == 1)
    }

    /// A user's chunk is recorded as the same block of a prompt would be: a link as a
    /// mention, an image as an image — not as the text either stands for.
    @Test func aUsersChunkIsRecordedAsAPromptsBlockIs() throws {
        var record = Self.record()
        try Self.apply(#"""
            {"sessionUpdate":"user_message_chunk","content":{"type":"resource_link","uri":"file:///tmp/a.txt",
            "name":"a.txt"}}
            """#, to: &record)
        try Self.apply(#"""
            {"sessionUpdate":"user_message_chunk","content":{"type":"image","mimeType":"image/png",
            "data":"iVBORw0KGgo="}}
            """#, to: &record)
        guard case .array(let messages)? = try Self.written(record)["messages"], messages.count == 2 else {
            throw POSIXError(.EINVAL)
        }
        #expect(messages[0]["User"]?["content"]?.stringified == #"[{"Mention":{"uri":"file:///tmp/a.txt","content":"a.txt"}}]"#)
        #expect(messages[1]["User"]?["content"]?.stringified
            == #"[{"Image":{"source":"iVBORw0KGgo=","mime_type":"image/png","size":null}}]"#)
    }

    /// A prompt's image and audio clip are recorded with their data and MIME type, as acpx
    /// 0.19.3 records them (openclaw/acpx#766, #88): `{source, mime_type, size: null}`
    /// for an image, `{source, mime_type}` for audio.
    @Test func aPromptsImageAndAudioAreRecordedWithTheirData() throws {
        var record = Self.record()
        ConversationModel.recordPromptSubmission(into: &record, prompt: [
            .text(TextContent(text: "look")),
            .image(ImageContent(data: "iVBORw0KGgo=", mimeType: "image/png")),
            .audio(AudioContent(data: "UklGRg==", mimeType: "audio/wav"))
        ])
        guard case .array(let messages)? = try Self.written(record)["messages"] else { throw POSIXError(.EINVAL) }
        #expect(messages.first?["User"]?["content"]?.stringified == #"[{"Text":"look"},"#
            + #"{"Image":{"source":"iVBORw0KGgo=","mime_type":"image/png","size":null}},"#
            + #"{"Audio":{"source":"UklGRg==","mime_type":"audio/wav"}}]"#)
    }
}
