@testable import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Which of a tool update's payloads are recorded as the agent sent them (#119).
@Suite struct ToolPayloadWireFormTests {
    /// The decoded update's payloads, read from `text` as the connection reads them.
    static func decoded(_ text: String) throws -> [String: JSONValue] {
        guard case .object(let members) = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return members
    }

    /// A payload holding a large integer keeps the agent's order, whatever number type each side
    /// read it as (#242 review).
    @Test func aPayloadWithALargeIntegerKeepsItsOrder() throws {
        let text = #"{"toolCallId":"t","rawInput":{"z":9000000000000000,"a":1,"n":[1.5,{"y":true,"b":null}]},"#
            + #""rawOutput":{"q":18446744073709551615,"c":"x"}}"#
        let raw = try #require(WireJSON(parsing: text))
        let decoded = try Self.decoded(text)
        let forms = ConversationModel.ToolFields.wireForms(
            in: raw, of: "t", input: decoded["rawInput"], output: decoded["rawOutput"])
        #expect(forms.input?.stringified == #"{"z":9000000000000000,"a":1,"n":[1.5,{"y":true,"b":null}]}"#)
        #expect(forms.output?.stringified == #"{"q":18446744073709552000,"c":"x"}"#)
    }

    /// A payload with a repeated member is recorded as JavaScript's `JSON.parse` reads it — the
    /// member once, in its first place, with its last value — at every depth, as acpx records it;
    /// Foundation reads the first value (#242 review).
    @Test func aRepeatedMemberIsRecordedAsJavaScriptReadsIt() throws {
        let text = #"{"toolCallId":"t","rawInput":{"a":1,"b":{"x":1,"x":2},"a":3}}"#
        let raw = try #require(WireJSON(parsing: text))
        let forms = ConversationModel.ToolFields.wireForms(
            in: raw, of: "t", input: try Self.decoded(text)["rawInput"], output: nil)
        #expect(forms.input?.stringified == #"{"a":3,"b":{"x":2}}"#)
    }

    /// Another tool's update — not the one decoded — gives none, nor does a payload the decoded
    /// update lacks, nor one that is no object or array.
    @Test func onlyTheDecodedUpdatesPayloadsAreTaken() throws {
        let text = #"{"toolCallId":"t","rawInput":{"z":1,"a":2},"rawOutput":"text"}"#
        let raw = try #require(WireJSON(parsing: text))
        let decoded = try Self.decoded(text)
        let other = ConversationModel.ToolFields.wireForms(
            in: raw, of: "u", input: decoded["rawInput"], output: decoded["rawOutput"])
        #expect(other.input == nil && other.output == nil)
        let forms = ConversationModel.ToolFields.wireForms(in: raw, of: "t", input: nil, output: decoded["rawOutput"])
        #expect(forms.input == nil && forms.output == nil)
    }
}
