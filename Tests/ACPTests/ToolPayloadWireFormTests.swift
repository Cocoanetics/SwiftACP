@testable import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Which of a tool update's payloads are recorded as the agent sent them (#119).
@Suite struct ToolPayloadWireFormTests {
    /// A payload holding a large integer keeps the agent's order: the number is the same to
    /// JSONFoundation, which reads it as an integer, and to the wire form, a double (#242 review).
    @Test func aPayloadWithALargeIntegerKeepsItsOrder() throws {
        let text = #"{"rawInput":{"z":9000000000000000,"a":1,"n":[1.5,{"y":true,"b":null}]},"#
            + #""rawOutput":{"q":18446744073709551615,"c":"x"}}"#
        let raw = try #require(WireJSON(parsing: text))
        guard case .object(let decoded) = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            Issue.record("not an object")
            return
        }
        let forms = ConversationModel.ToolFields.wireForms(
            in: raw, input: decoded["rawInput"], output: decoded["rawOutput"])
        #expect(forms.input?.stringified == #"{"z":9000000000000000,"a":1,"n":[1.5,{"y":true,"b":null}]}"#)
        #expect(forms.output?.stringified == #"{"q":18446744073709552000,"c":"x"}"#)
    }

    /// A wire form that does not hold what was decoded is not taken.
    @Test func aPayloadThatIsNotWhatWasDecodedIsNotTaken() throws {
        let raw = try #require(WireJSON(parsing: #"{"rawInput":{"z":1,"a":2}}"#))
        let other = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"z":1,"a":3}"#.utf8))
        #expect(ConversationModel.ToolFields.wireForms(in: raw, input: other, output: nil).input == nil)
        let fewer = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"z":1}"#.utf8))
        #expect(ConversationModel.ToolFields.wireForms(in: raw, input: fewer, output: nil).input == nil)
    }
}
