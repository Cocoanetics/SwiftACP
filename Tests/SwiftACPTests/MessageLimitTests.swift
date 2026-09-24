@testable import SwiftACP
import Foundation
import JSONFoundation
import JSONRPCPeer
import JSONRPCWire
import Testing

/// The ACP message limit where an agent is read through a ``MessageFraming`` — on the
/// platforms without ``AgentProcessTransport`` (#113 review): a line past the limit ends
/// the connection with ``AcpMessageLimitError``, after what was read before it.
@Suite(.timeLimit(.minutes(1)))
struct MessageLimitTests {
    /// The line in progress is counted across chunks, as acpx's `countLineBytes` counts
    /// it; past the limit nothing more is read.
    @Test func aLinePastTheLimitStopsTheReading() {
        let signal = MessageLimit.Signal()
        var framing = MessageLimit.Framing(LineFraming(), limit: 10, signal: signal)
        #expect(framing.push(Data("abc\n0123".utf8)) == [Data("abc".utf8)])
        #expect(framing.push(Data("456789".utf8)).isEmpty)
        #expect(signal.exceeded == nil)
        #expect(framing.push(Data("X\n{}\n".utf8)).isEmpty)
        #expect(signal.exceeded == AcpMessageLimitError(limit: 10))
        #expect(framing.push(Data("{}\n".utf8)).isEmpty)
    }

    /// The transport under it is closed, and its stream ends with the limit's error once
    /// everything read before has gone out.
    @Test func theConnectionEndsWithTheLimitAfterWhatCameBefore() async throws {
        let (client, server) = LoopbackTransport.pair()
        let signal = MessageLimit.Signal()
        let transport = MessageLimit.Transport(client, signal: signal)
        let inbound = transport.makeInboundStream()
        try server.send(.notification(method: "before"))
        signal.fire(AcpMessageLimitError(limit: 10))
        var methods: [String] = []
        let error = await #expect(throws: AcpMessageLimitError.self) {
            for try await message in inbound {
                if case .notification(let notification) = message { methods.append(notification.method) }
            }
        }
        #expect(error == AcpMessageLimitError(limit: 10))
        #expect(methods == ["before"])
        #expect(throws: JSONRPCPeerError.self) { try server.send(.notification(method: "after")) }
    }
}
