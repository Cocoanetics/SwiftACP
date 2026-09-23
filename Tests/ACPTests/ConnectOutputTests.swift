@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// A turn shows how its agent was connected, as acpx shows it (#53): the messages of
/// connecting it, buffered and flushed once connected — without a failed `session/load`
/// or `session/resume` that a new session replaced — then the turn.
extension DaemonToolsTests {
    private static func body(_ json: String) -> Data { Data(json.utf8) }

    private static func methods(_ events: [WireMessageEvent]) -> [String] {
        events.map { event in
            let message = WireJSON(parsing: Data(event.wireLine.utf8))
            return message?["method"]?.stringValue ?? (message?.hasMember("error") == true ? "error" : "result")
        }
    }

    /// acpx's `filterRecoverableLoadFallbackOutput`: after a fallback, the failed
    /// reconnect request and its error response go; everything else stays, in order.
    @Test func aFailedReconnectIsLeftOutOnlyAfterAFallback() {
        let buffer = ConnectOutputBuffer()
        let messages: [(JSONRPCPeer.WireDirection, String)] = [
            (.outbound, #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#),
            (.inbound, #"{"jsonrpc":"2.0","id":0,"result":{}}"#),
            (.outbound, #"{"jsonrpc":"2.0","id":1,"method":"session/load","params":{}}"#),
            (.inbound, #"{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"gone"}}"#),
            (.outbound, #"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{}}"#),
            (.inbound, #"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s"}}"#),
            (.outbound, #"{"jsonrpc":"2.0","id":"1","method":"session/set_mode","params":{}}"#),
            (.inbound, #"{"jsonrpc":"2.0","id":"1","result":{}}"#)
        ]
        for (direction, json) in messages { buffer.observer(direction, Self.body(json)) }
        #expect(Self.methods(buffer.flush(fellBack: true))
            == ["initialize", "result", "session/new", "result", "session/set_mode", "result"])
        #expect(Self.methods(buffer.flush(fellBack: false))
            == ["initialize", "result", "session/load", "error", "session/new", "result", "session/set_mode", "result"])
    }

    /// Connecting for a turn is shown, the agent's start-up included — with the failed
    /// load left out when a new session took its place.
    @Test(.enabled(if: mockPythonAvailable))
    func connectingForATurnIsShownAsAcpxShowsIt() async throws {
        for (mode, expected) in [
            ("ok", ["initialize", "result", "session/load", "result"]),
            ("gone", ["initialize", "result", "session/new", "result"])
        ] {
            try await withLoggedMock(loadMode: mode) { command, _ in
                let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                    .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
                let record = try #require(SessionStore.loadRecord(id))
                let (shown, show) = AsyncStream<[WireMessageEvent]>.makeStream()
                let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
                _ = try await daemon.ensure(
                    recordId: id, agentCommand: record.agentCommand, cwd: record.cwd, mcpServers: nil,
                    onConnectOutput: { show.yield($0) })
                show.finish()
                let output = await shown.first { _ in true }
                #expect(Self.methods(output ?? []) == expected, "\(mode)")
                // Held now: a later turn has nothing to show.
                let (again, showAgain) = AsyncStream<[WireMessageEvent]>.makeStream()
                _ = try await daemon.ensure(
                    recordId: id, agentCommand: record.agentCommand, cwd: record.cwd, mcpServers: nil,
                    onConnectOutput: { showAgain.yield($0) })
                showAgain.finish()
                #expect(await again.first { _ in true } == nil, "\(mode)")
            }
        }
    }

    /// In text mode a forwarded request is a `[client]` line and anything else nothing;
    /// in JSON wire mode every message is printed as acpx prints it.
    @Test func forwardedMessagesRenderAsAcpxRendersThem() {
        final class Output: @unchecked Sendable {
            var text = ""
        }
        let request = WireMessageEvent(
            wireDirection: "outbound", wireLine: #"{"jsonrpc":"2.0","id":1,"method":"session/load","params":{}}"#)
        let result = WireMessageEvent(wireDirection: "inbound", wireLine: #"{"jsonrpc":"2.0","id":1,"result":{}}"#)

        let text = Output()
        let textRenderer = OutputRenderer(
            options: RenderOptions(format: .text, streamsWire: true), out: { text.text += $0 }, color: false)
        textRenderer.wireMessage(request)
        textRenderer.wireMessage(result)
        #expect(text.text == "[client] session/load (running)\n")

        let json = Output()
        let jsonRenderer = OutputRenderer(
            options: RenderOptions(format: .json, streamsWire: true), out: { json.text += $0 }, color: false)
        jsonRenderer.wireMessage(request)
        jsonRenderer.wireMessage(result)
        #expect(json.text == request.wireLine + "\n" + result.wireLine + "\n")
    }
}
