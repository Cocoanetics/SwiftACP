import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// The replies that open a session and set an option are read as acpx reads them: its ACP
/// SDK checks no reply, so a member the schema would not take fails nothing.
/// A session reply's `configOptions` and `models` are kept as sent, `null` apart from none;
/// an option reply's `configOptions` only when it is a list (acpx 0.19.4, openclaw/acpx#809);
/// and `modes` is read as the ACP schema reads it (`zSessionModeState`), left out when it
/// doesn't fit.
struct SessionReplyDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func configOptionsAreKeptAsSent() throws {
        let cases: [(String, JSONValue?)] = [
            (#"{"sessionId":"s"}"#, nil),
            (#"{"sessionId":"s","configOptions":null}"#, .null),
            (#"{"sessionId":"s","configOptions":"oops"}"#, .string("oops")),
            (#"{"sessionId":"s","configOptions":{"a":1}}"#, .object(["a": .integer(1)])),
            (#"{"sessionId":"s","configOptions":[{"id":"x"},"str"]}"#,
             .array([.object(["id": .string("x")]), .string("str")]))
        ]
        for (json, raw) in cases {
            let reply = try decode(NewSessionResponse.self, json)
            #expect(reply.rawConfigOptions == raw, "\(json)")
            #expect(reply.configOptions == raw?.arrayValue, "\(json)")
            let loaded = try decode(LoadSessionResponse.self, json)
            #expect(loaded.rawConfigOptions == raw, "\(json)")
            // An option reply keeps only a list.
            let set = try decode(SetSessionConfigOptionResponse.self, json)
            #expect(set.rawConfigOptions == (raw?.arrayValue == nil ? nil : raw), "\(json)")
        }
    }

    @Test func aNullModelListIsKept() throws {
        #expect(try decode(NewSessionResponse.self, #"{"sessionId":"s","models":null}"#).models == .null)
        #expect(try decode(LoadSessionResponse.self, #"{"models":null}"#).models == .null)
        #expect(try decode(LoadSessionResponse.self, "{}").models == nil)
    }

    @Test func modesTheSchemaWouldNotTakeAreLeftOut() throws {
        for modes in [
            #""oops""#, "[]", #"{"availableModes":[]}"#, #"{"currentModeId":"plan"}"#,
            #"{"currentModeId":7,"availableModes":[]}"#
        ] {
            let reply = try decode(NewSessionResponse.self, #"{"sessionId":"s","modes":\#(modes)}"#)
            #expect(reply.modes == nil, "\(modes)")
            #expect(try decode(LoadSessionResponse.self, #"{"modes":\#(modes)}"#).modes == nil, "\(modes)")
        }
    }

    /// A mode list that isn't one reads as empty (`requiredDefaultOnError`), a mode that
    /// doesn't fit is left out (`vecSkipError`), and so is a description that is no string.
    @Test func modesAreReadAsTheSchemaReadsThem() throws {
        let plan = SessionMode(id: "plan", name: "Plan")
        let cases: [(String, [SessionMode])] = [
            (#"{"currentModeId":"plan","availableModes":"x"}"#, []),
            (#"{"currentModeId":"plan","availableModes":null}"#, []),
            (#"{"currentModeId":"plan","availableModes":[{"id":"plan","name":"Plan"},{"id":1},"str"]}"#, [plan]),
            (#"{"currentModeId":"plan","availableModes":[{"id":"plan","name":"Plan","description":7}]}"#, [plan]),
            (#"{"currentModeId":"plan","availableModes":[{"id":"plan","name":"Plan","description":"Think"}]}"#,
             [SessionMode(id: "plan", name: "Plan", description: "Think")])
        ]
        for (modes, available) in cases {
            let reply = try decode(NewSessionResponse.self, #"{"sessionId":"s","modes":\#(modes)}"#)
            #expect(reply.modes == SessionModeState(currentModeId: "plan", availableModes: available), "\(modes)")
        }
    }

    /// acpx asks a load reply for its members with `in`: `null`, or a list, has none, and
    /// anything else that is no object fails it.
    @Test func aLoadReplyThatIsNullOrAListReportsNothing() throws {
        for json in ["null", "[]", #"["x"]"#] {
            let reply = try decode(LoadSessionResponse.self, json)
            #expect(reply.rawConfigOptions == nil && reply.models == nil && reply.modes == nil, "\(json)")
        }
        #expect(throws: DecodingError.self) { try decode(LoadSessionResponse.self, #""oops""#) }
        #expect(throws: DecodingError.self) { try decode(LoadSessionResponse.self, "5") }
    }

    /// acpx reads the `configOptions` of a reply that is no object as undefined: it only
    /// acknowledges.
    @Test func anOptionReplyThatIsNoObjectOnlyAcknowledges() throws {
        for json in ["null", #""oops""#, "5", "true", "[]"] {
            #expect(try decode(SetSessionConfigOptionResponse.self, json).rawConfigOptions == nil, "\(json)")
        }
    }

    /// acpx 0.19.4's `normalizeConfigOptionAcknowledgement` (openclaw/acpx#809): a reply whose
    /// `configOptions` is no list only acknowledges too — read with that member deleted — while
    /// a list is kept as sent.
    @Test func anOptionReplyWhoseOptionsAreNoListOnlyAcknowledges() throws {
        for options in ["null", "5", #""oops""#, "{}", "true"] {
            let reply = #"{"configOptions":\#(options)}"#
            #expect(try decode(SetSessionConfigOptionResponse.self, reply).rawConfigOptions == nil, "\(reply)")
        }
        #expect(try decode(SetSessionConfigOptionResponse.self, #"{"configOptions":[null,"x"]}"#).rawConfigOptions
            == .array([.null, .string("x")]))
    }

    @Test func aNullListIsWrittenAsSent() throws {
        var reply = NewSessionResponse(sessionId: "s")
        #expect(try JSONValue(encoding: reply) == .object(["sessionId": .string("s")]))
        reply.rawConfigOptions = .null
        #expect(try JSONValue(encoding: reply) == .object(["sessionId": .string("s"), "configOptions": .null]))
        // An option reply's options go out as set, and come back only as a list.
        var set = SetSessionConfigOptionResponse()
        set.rawConfigOptions = .string("oops")
        let written = try JSONEncoder().encode(set)
        #expect(String(decoding: written, as: UTF8.self) == #"{"configOptions":"oops"}"#)
        #expect(try JSONDecoder().decode(SetSessionConfigOptionResponse.self, from: written).rawConfigOptions == nil)
    }

    /// The daemon hands the CLI the reply's options as sent, for it echoes them.
    @Test func aControlResultKeepsTheRepliedOptionsAsSent() throws {
        for raw in [JSONValue.null, .string("oops"), .array([])] {
            let written = try JSONEncoder().encode(SessionControlResult(resumed: true, rawConfigOptions: raw))
            let read = try JSONDecoder().decode(SessionControlResult.self, from: written)
            #expect(read.rawConfigOptions == raw && read.resumed)
        }
        let acknowledged = try JSONEncoder().encode(SessionControlResult(resumed: false))
        #expect(try JSONDecoder().decode(SessionControlResult.self, from: acknowledged).rawConfigOptions == nil)
    }
}
