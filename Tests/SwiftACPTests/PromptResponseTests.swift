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

    @Test func unknownStopReasonAndSnakeCaseUsagePreserveGenuineMetadataWithoutSessionFailure() throws {
        let json =
            #"{"stopReason":"adapter_custom_stop","#
            + #""usage":{"input_tokens":26726,"output_tokens":1019,"thought_tokens":571,"total_tokens":27745},"#
            + #""_meta":{"provider":{"trace":"synthetic-1"}}}"#
        let decoded = try JSONDecoder().decode(PromptResponse.self, from: Data(json.utf8))
        #expect(decoded.stopReason == StopReason(rawValue: "adapter_custom_stop"))
        #expect(decoded.stopReason.rawValue == "adapter_custom_stop")
        #expect(decoded.usage?.inputTokens == 26_726)
        #expect(decoded.usage?.outputTokens == 1019)
        #expect(decoded.usage?.thoughtTokens == 571)
        #expect(decoded.usage?.totalTokens == 27_745)
        #expect(decoded.meta == .object(["provider": .object(["trace": .string("synthetic-1")])]))
        #expect(decoded.sessionFailure == nil)
        #expect(try decoded.throwingSessionFailure().stopReason.rawValue == "adapter_custom_stop")

        let encoded = try JSONEncoder().encode(decoded)
        let roundTrip = try JSONDecoder().decode(PromptResponse.self, from: encoded)
        #expect(roundTrip.stopReason == decoded.stopReason)
        #expect(roundTrip.usage?.thoughtTokens == 571)
        #expect(roundTrip.meta == decoded.meta)
    }

    @Test func cancelledResponseWithUsageAndMetaPreservesBothIndependently() throws {
        let json =
            #"{"stopReason":"cancelled","usage":{"inputTokens":12,"outputTokens":0,"thoughtTokens":8,"#
            + #""totalTokens":20},"_meta":{"source":"synthetic-cancel"}}"#
        let decoded = try JSONDecoder().decode(PromptResponse.self, from: Data(json.utf8))
        #expect(decoded.stopReason == .cancelled)
        #expect(decoded.usage?.inputTokens == 12)
        #expect(decoded.usage?.outputTokens == 0)
        #expect(decoded.usage?.thoughtTokens == 8)
        #expect(decoded.usage?.totalTokens == 20)
        #expect(decoded.meta == .object(["source": .string("synthetic-cancel")]))
        #expect(decoded.sessionFailure == nil)
    }
}
