import Foundation
import JSONFoundation
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
        let first = try #require(tap.takeUpdateBody())
        #expect(first["update"]?["rawInput"]?.stringified == #"{"z":1,"a":2}"#)
        #expect(tap.takeUpdateBody() != nil)
        #expect(tap.takeUpdateBody() == nil)
    }

    /// Each update the peer hands on takes its own body, in order, as it is: never matched against
    /// the update as decoded, which takes a member written twice as its first, where the body — as
    /// acpx reads it — has the last. So the next update's body stays the next's (#242 review).
    @Test func eachUpdateTakesItsOwnBodyAsItIs() throws {
        let tap = RawWireTap()
        tap.keepUpdateBodies()
        let batch = #"[{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","sessionId":"other","#
            + #""update":{"sessionUpdate":"tool_call","toolCallId":"t","rawInput":{"z":1,"a":2}}}},"#
            + #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"tool_call","toolCallId":"t","rawInput":{"second":true}}}}]"#
        tap.observe(.inbound, Data(batch.utf8))
        let first = try #require(tap.takeUpdateBody())
        #expect(first["update"]?["rawInput"]?.stringified == #"{"z":1,"a":2}"#)
        #expect(first["sessionId"]?.stringValue == "other")
        #expect(tap.takeUpdateBody()?["update"]?["rawInput"]?.stringified == #"{"second":true}"#)
        #expect(tap.takeUpdateBody() == nil)
    }

    /// At the connection, each update the agent sends carries its own body — one with a member
    /// written twice too, and the update after it — as the transport reads each and the peer
    /// hands it on (#242 review).
    @Test(.timeLimit(.minutes(1)))
    func eachUpdateCarriesItsOwnBodyAtTheConnection() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let tap = RawWireTap()
        let connection = ACPAgentConnection(transport: clientEnd, rawUpdates: tap)
        await connection.start()
        let (subscription, stream) = await connection.makeEventSubscription()
        let bodies = [
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","sessionId":"other","#
                + #""update":{"sessionUpdate":"tool_call","toolCallId":"t","title":"Read","rawInput":{"z":1,"a":2}}}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
                + #"{"sessionUpdate":"tool_call","toolCallId":"t","title":"Read","rawInput":{"second":true}}}}"#
        ]
        // As a transport reads each: the tap sees the body, then the peer gets what it decodes to.
        for body in bodies {
            tap.observe(.inbound, Data(body.utf8))
            for message in try JSONRPCMessage.decodeMessages(from: Data(body.utf8)) { try agentEnd.send(message) }
        }
        var raw: [String?] = []
        for await event in stream {
            guard case .update(let note) = event else { continue }
            raw.append(note.rawUpdate?["rawInput"]?.stringified)
            if raw.count == 2 { break }
        }
        await connection.endSubscription(subscription)
        #expect(raw == [#"{"z":1,"a":2}"#, #"{"second":true}"#])
    }

    /// An update written twice in one notification is the last one, as acpx's `JSON.parse` reads
    /// it — the update and the payloads it carries as written both — never the first update with
    /// the second's payloads (#242 review).
    @Test(.timeLimit(.minutes(1)))
    func anUpdateWrittenTwiceIsTheLastOne() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let tap = RawWireTap()
        let connection = ACPAgentConnection(transport: clientEnd, rawUpdates: tap)
        await connection.start()
        let (subscription, stream) = await connection.makeEventSubscription()
        let body = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","#
            + #""update":{"sessionUpdate":"tool_call","toolCallId":"t","title":"First","rawInput":{"first":true}},"#
            + #""update":{"sessionUpdate":"tool_call","toolCallId":"t","title":"Second","rawInput":{"second":true}}}}"#
        tap.observe(.inbound, Data(body.utf8))
        for message in try JSONRPCMessage.decodeMessages(from: Data(body.utf8)) { try agentEnd.send(message) }
        var seen: (title: String, raw: String?)?
        for await event in stream {
            guard case .update(let note) = event, case .toolCall(let call) = note.update else { continue }
            seen = (call.title, note.rawUpdate?["rawInput"]?.stringified)
            break
        }
        await connection.endSubscription(subscription)
        #expect(seen?.title == "Second")
        #expect(seen?.raw == #"{"second":true}"#)
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
        let first = try #require(tap.takeUpdateBody())
        #expect(first["update"]?["rawInput"]?.stringified == #"{"z":1,"a":2}"#)
        #expect(tap.takeUpdateBody() != nil)
        #expect(tap.takeUpdateBody() == nil)
    }

    /// An update without `params` keeps an entry of its own, which its handler — asking with no
    /// session and no kind — takes, so the update after it gets its own body (#242 review).
    @Test func anUpdateWithoutParamsKeepsItsPlace() throws {
        let tap = RawWireTap()
        tap.keepUpdateBodies()
        let batch = #"[{"jsonrpc":"2.0","method":"session/update"},"#
            + #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"tool_call","toolCallId":"t","rawInput":{"z":1,"a":2}}}}]"#
        tap.observe(.inbound, Data(batch.utf8))
        #expect(tap.takeUpdateBody() == nil)
        let next = try #require(tap.takeUpdateBody())
        #expect(next["update"]?["rawInput"]?.stringified == #"{"z":1,"a":2}"#)
    }

    /// A long batch is handed on in order, each update its own body, however the takes interleave
    /// with bodies kept later: the taken ones are dropped in bulk, never shifted one by one
    /// (#242 review).
    @Test func aLongBatchIsHandedOnInOrder() throws {
        let tap = RawWireTap()
        tap.keepUpdateBodies()
        func batch(_ calls: Range<Int>) -> Data {
            let updates = calls.map {
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
                    + #"{"sessionUpdate":"tool_call","toolCallId":"t\#($0)"}}}"#
            }
            return Data("[\(updates.joined(separator: ","))]".utf8)
        }
        func taken() -> String? {
            tap.takeUpdateBody()?["update"]?["toolCallId"]?.stringValue
        }
        tap.observe(.inbound, batch(0..<5_000))
        let first = (0..<3_000).map { _ in taken() }
        tap.observe(.inbound, batch(5_000..<5_010))
        let rest = (3_000..<5_010).map { _ in taken() }
        #expect(first + rest == (0..<5_010).map { Optional("t\($0)") })
        #expect(taken() == nil)
    }

    /// A tap no connection took the bodies of keeps none.
    @Test func aTapKeepsNoneUnlessAsked() {
        let tap = RawWireTap()
        let body = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"plan"}}}"#
        tap.observe(.inbound, Data(body.utf8))
        #expect(tap.takeUpdateBody() == nil)
    }

    /// The tap keeps the `result` of the agent's answer to a request acpx records the answer of as
    /// written — paired to it by id, from a batch too — for its method and the session it names,
    /// until taken; `session/new` names its session in its answer. Nothing else is kept: the answer
    /// to another method, an error, or an answer no request asked for (#119).
    @Test func answersAreKeptAsWrittenForTheirRequests() {
        let tap = RawWireTap()
        func out(_ line: String) { tap.observe(.outbound, Data(line.utf8)) }
        func into(_ line: String) { tap.observe(.inbound, Data(line.utf8)) }
        into(#"{"jsonrpc":"2.0","id":1,"result":{"early":true}}"#)
        out(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        out(#"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s"}}"#)
        out(#"{"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"/"}}"#)
        out(#"{"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"s"}}"#)
        out(#"{"jsonrpc":"2.0","id":5,"method":"session/load","params":{"sessionId":"t"}}"#)
        into(#"[{"jsonrpc":"2.0","method":"x"},{"jsonrpc":"2.0","id":1,"result":{"zeta":1,"alpha":2}}]"#)
        into(#"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#)
        into(#"{"jsonrpc":"2.0","id":3,"result":{"sessionId":"n","configOptions":[{"type":"select","id":"m"}]}}"#)
        into(#"{"jsonrpc":"2.0","id":4,"result":{"configOptions":[{"z":1,"a":2}]}}"#)
        into(#"{"jsonrpc":"2.0","id":5,"error":{"code":-32603,"message":"no"}}"#)
        into(#"{"jsonrpc":"2.0","id":5,"result":{"late":true}}"#)

        #expect(tap.takeResult(of: "initialize", sessionId: nil)?.stringified == #"{"zeta":1,"alpha":2}"#)
        #expect(tap.takeResult(of: "initialize", sessionId: nil) == nil)
        #expect(tap.takeResult(of: "session/prompt", sessionId: "s") == nil)
        #expect(tap.takeResult(of: "session/new", sessionId: "n")?["configOptions"]?.stringified
            == #"[{"type":"select","id":"m"}]"#)
        #expect(tap.takeResult(of: "session/set_config_option", sessionId: "s")?.stringified
            == #"{"configOptions":[{"z":1,"a":2}]}"#)
        #expect(tap.takeResult(of: "session/load", sessionId: "t") == nil)
    }
}
