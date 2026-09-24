import Foundation
import SwiftACP
import Testing

/// A content block goes on as it came: acpx sends a prompt's blocks to the agent as
/// written, so what SwiftACP decodes it re-encodes with the same members (#103).
struct ContentBlockTests {
    private func roundTrip(_ json: String) throws -> [String: Any] {
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(block)
        return try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    }

    @Test func aNullTitleStaysNull() throws {
        let link = try roundTrip(#"{"type":"resource_link","uri":"u","name":"n","title":null}"#)
        #expect(link["title"] is NSNull)
        let untitled = try roundTrip(#"{"type":"resource_link","uri":"u","name":"n"}"#)
        #expect(untitled["title"] == nil)
    }

    @Test func eachBlockKeepsItsMeta() throws {
        for json in [
            #"{"type":"text","text":"t","_meta":{"k":1}}"#,
            #"{"type":"image","mimeType":"image/png","data":"aGk=","_meta":{"k":1}}"#,
            #"{"type":"audio","mimeType":"audio/wav","data":"aGk=","_meta":{"k":1}}"#,
            #"{"type":"resource_link","uri":"u","name":"n","_meta":{"k":1}}"#,
            #"{"type":"resource","resource":{"uri":"u","text":"t","_meta":{"k":2}},"_meta":{"k":1}}"#
        ] {
            let block = try roundTrip(json)
            #expect((block["_meta"] as? [String: Any])?["k"] as? Int == 1, "\(json)")
        }
        let resource = try roundTrip(#"{"type":"resource","resource":{"uri":"u","blob":"aGk=","_meta":{"k":2}}}"#)
        #expect(((resource["resource"] as? [String: Any])?["_meta"] as? [String: Any])?["k"] as? Int == 2)
    }
}
