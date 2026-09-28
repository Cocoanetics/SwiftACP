import Foundation
@testable import SwiftACP
import Testing

/// The bodies a tap keeps for the connection that handles an agent's `session/update`s (#119).
@Suite struct RawUpdateBodyTests {
    /// An update is kept however its method is spelled — `"session\/update"`, as Foundation's
    /// encoder writes it, is the same method — and handed on in order, as the agent wrote it.
    @Test func anUpdateIsKeptHoweverItsMethodIsSpelled() throws {
        let tap = RawWireTap()
        tap.keepUpdateBodies()
        let escaped = #"{"jsonrpc":"2.0","method":"session\/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"tool_call","toolCallId":"t","rawInput":{"z":1,"a":2}}}}"#
        let plain = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"plan","entries":[]}}}"#
        tap.observe(.inbound, Data(escaped.utf8))
        tap.observe(.inbound, Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        tap.observe(.inbound, Data(plain.utf8))
        let first = try #require(tap.takeUpdateBody(sessionId: "s", kind: "tool_call"))
        #expect(first["update"]?["rawInput"]?.stringified == #"{"z":1,"a":2}"#)
        #expect(tap.takeUpdateBody(sessionId: "s", kind: "plan") != nil)
        #expect(tap.takeUpdateBody(sessionId: "s", kind: "plan") == nil)
    }

    /// A kept body that is not the update being handled — never handled as one — is dropped,
    /// so the next update gets its own.
    @Test func aBodyNeverHandledIsDropped() throws {
        let tap = RawWireTap()
        tap.keepUpdateBodies()
        for (session, kind) in [("other", "plan"), ("s", "tool_call")] {
            let body = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(session)","#
                + #""update":{"sessionUpdate":"\#(kind)"}}}"#
            tap.observe(.inbound, Data(body.utf8))
        }
        #expect(tap.takeUpdateBody(sessionId: "s", kind: "tool_call")?["sessionId"]?.stringValue == "s")
        #expect(tap.takeUpdateBody(sessionId: "s", kind: "tool_call") == nil)
    }

    /// A body the peer does not take as a notification is never kept, though it parses as JSON
    /// with the method last: a repeated `method` whose first value is no string fails the peer's
    /// decoding, so the next update gets its own body; a batch's updates are kept each in turn
    /// (#242 review).
    @Test func onlyWhatThePeerTakesAsAnUpdateIsKept() throws {
        let tap = RawWireTap()
        tap.keepUpdateBodies()
        let rejected = #"{"jsonrpc":"2.0","method":1,"method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"tool_call","toolCallId":"t","rawInput":{"stale":true}}}}"#
        let batch = #"[{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"tool_call","toolCallId":"t","rawInput":{"z":1,"a":2}}}},"#
            + #"{"jsonrpc":"2.0","id":7,"result":{}},"#
            + #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"plan"}}}]"#
        tap.observe(.inbound, Data(rejected.utf8))
        tap.observe(.inbound, Data(batch.utf8))
        let first = try #require(tap.takeUpdateBody(sessionId: "s", kind: "tool_call"))
        #expect(first["update"]?["rawInput"]?.stringified == #"{"z":1,"a":2}"#)
        #expect(tap.takeUpdateBody(sessionId: "s", kind: "plan") != nil)
        #expect(tap.takeUpdateBody(sessionId: "s", kind: "plan") == nil)
    }

    /// A tap no connection took the bodies of keeps none.
    @Test func aTapKeepsNoneUnlessAsked() {
        let tap = RawWireTap()
        let body = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"plan"}}}"#
        tap.observe(.inbound, Data(body.utf8))
        #expect(tap.takeUpdateBody(sessionId: "s", kind: "plan") == nil)
    }
}
