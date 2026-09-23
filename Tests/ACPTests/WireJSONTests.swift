@testable import ACPXCore
import Foundation
import Testing

/// `WireJSON` must print what acpx prints: `JSON.stringify(JSON.parse(line))`.
@Suite struct WireJSONTests {
    private struct Case: Decodable {
        let input: String
        /// What Node printed, or `nil` where `JSON.parse` threw.
        let output: String?
    }

    /// Every expectation in the fixture was printed by Node 25 — key order (array-index
    /// keys first), repeated keys, number forms, escapes, lone surrogates, and the
    /// inputs `JSON.parse` rejects.
    @Test func printsWhatJavaScriptPrints() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/wirejson-node.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixture))
        #expect(cases.count > 20)
        for testCase in cases {
            #expect(WireJSON(parsing: testCase.input)?.stringified == testCase.output, "\(testCase.input)")
        }
    }

    /// Bytes that are not UTF-8 read as U+FFFD, the way `TextDecoder` reads them.
    @Test func invalidUTF8BecomesTheReplacementCharacter() {
        let bytes = Data([0x22, 0x61, 0xFF, 0x62, 0x22])  // "a<0xFF>b"
        #expect(WireJSON(parsing: bytes)?.stringified == "\"a\u{FFFD}b\"")
    }

    /// Absurd nesting is refused rather than recursed into.
    @Test func refusesNestingPastTheLimit() {
        let deep = String(repeating: "[", count: WireJSON.maxDepth + 2)
            + String(repeating: "]", count: WireJSON.maxDepth + 2)
        #expect(WireJSON(parsing: deep) == nil)
        let fine = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(WireJSON(parsing: fine) != nil)
    }

    @Test func replacingKeepsTheMembersPosition() throws {
        let message = try #require(WireJSON(parsing: #"{"a":1,"content":"x","z":2}"#))
        #expect(message.replacing("content", with: .text("y")).stringified == #"{"a":1,"content":"y","z":2}"#)
        #expect(message.replacing("missing", with: .null) == message)
        #expect(message["content"]?.stringValue == "x")
        #expect(message.hasMember("z"))
    }
}
