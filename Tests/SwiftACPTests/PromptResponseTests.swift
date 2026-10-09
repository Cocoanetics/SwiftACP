import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

struct PromptResponseTests {
    @Test func metaRoundTripsIntact() throws {
        let json =
            #"{"stopReason":"end_turn","usage":{"inputTokens":50,"outputTokens":12633,"totalTokens":1451894},"#
            + #""_meta":{"quota":{"model_usage":[{"model":"claude-opus-5-5","token_count":{"totalTokens":1}}]}}}"#
        let decoded = try JSONDecoder().decode(PromptResponse.self, from: Data(json.utf8))
        #expect(decoded.stopReason == .endTurn)
        #expect(decoded.usage?.inputTokens == 50)
        #expect(decoded.meta?["quota"]?["model_usage"]?.arrayValue?.first?["model"]?.stringValue
            == "claude-opus-5-5")

        let encoded = try JSONEncoder().encode(decoded)
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let original = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(roundTrip == original)
    }

    @Test func aResponseWithoutMetaStillDecodesAndOmitsTheKeyWhenEncoded() throws {
        let json = #"{"stopReason":"cancelled"}"#
        let decoded = try JSONDecoder().decode(PromptResponse.self, from: Data(json.utf8))
        #expect(decoded.stopReason == .cancelled)
        #expect(decoded.meta == nil)

        let wire = try String(decoding: JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!wire.contains("_meta"))
        #expect(wire.contains("\"stopReason\":\"cancelled\""))
    }
}
