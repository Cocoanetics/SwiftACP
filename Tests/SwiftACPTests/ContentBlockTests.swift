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

    /// Members a block's type does not hold, and known ones sent as `null` or with a type
    /// it does not expect, go on as they came instead of failing the block or being
    /// dropped (#114 review).
    @Test func whateverElseABlockCarriedGoesOnAsItCame() throws {
        let text = try roundTrip(#"{"type":"text","text":"t","_meta":null,"x-custom":{"a":[1,"b"]}}"#)
        #expect(text["_meta"] is NSNull)
        #expect(((text["x-custom"] as? [String: Any])?["a"] as? [Any])?.count == 2)

        let resource = try roundTrip(#"{"type":"resource","resource":{"uri":"u","text":"t","blob":5}}"#)
        #expect((resource["resource"] as? [String: Any])?["blob"] as? Int == 5)
        #expect((resource["resource"] as? [String: Any])?["text"] as? String == "t")

        let link = try roundTrip(#"{"type":"resource_link","uri":"u","name":"n","size":1.5,"title":7}"#)
        #expect(link["size"] as? Double == 1.5)
        #expect(link["title"] as? Int == 7)
    }

    /// A member the block holds itself wins over one kept from how it came.
    @Test func aMemberSetSinceWinsOverTheOneThatCame() throws {
        var block = try JSONDecoder().decode(
            ResourceLink.self, from: Data(#"{"type":"resource_link","uri":"u","name":"n","title":null}"#.utf8))
        block.title = "set"
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String: Any])
        #expect(encoded["title"] as? String == "set")
    }
}
