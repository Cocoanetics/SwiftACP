@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// A turn shows how its agent was connected, as acpx shows it (#53): the messages of
/// connecting it, buffered and flushed once connected or once connecting failed —
/// without a failed `session/load` or `session/resume` that a new session replaced, and
/// without the history a load replays — then the turn.
extension DaemonToolsTests {
    private static func body(_ json: String) -> Data { Data(json.utf8) }

    private static func methods(_ events: [WireMessageEvent]) -> [String] {
        events.map { event in
            let message = WireJSON(parsing: Data(event.wireLine.utf8))
            return message?["method"]?.stringValue ?? (message?.hasMember("error") == true ? "error" : "result")
        }
    }

    /// acpx's `filterBufferedConnectOutput`: after a fallback, the failed reconnect
    /// request and its error response go; everything else stays, in order.
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

    /// The filter keys ids exactly as acpx's does: only a string or a finite number is
    /// an id, and `1` is not `"1"`. It pairs by direction, as acpx 0.19.3's does (#778,
    /// for our openclaw/acpx#764): an agent request that reuses the failed load's id, and
    /// the client's reply to it, are neither hidden nor hide anything, whenever they come;
    /// and each response settles the one request pending under its id. Every expectation
    /// is what acpx 0.19.3's filter makes of the same messages.
    @Test func theFallbackFilterKeysIdsAsAcpxDoes() {
        func flushed(_ messages: [(JSONRPCPeer.WireDirection, String)]) -> [String] {
            let buffer = ConnectOutputBuffer()
            for (direction, json) in messages { buffer.observer(direction, Self.body(json)) }
            return buffer.flush(fellBack: true).map { $0.wireLine }
        }
        let load = #"{"jsonrpc":"2.0","id":1,"method":"session/load","params":{}}"#
        let loadFailed = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"gone"}}"#
        let stringReply = #"{"jsonrpc":"2.0","id":"1","result":{}}"#
        #expect(flushed([(.outbound, load), (.inbound, loadFailed), (.inbound, stringReply)]) == [stringReply])

        let boolLoad = #"{"jsonrpc":"2.0","id":true,"method":"session/load","params":{}}"#
        let boolFailed = #"{"jsonrpc":"2.0","id":true,"error":{"code":-32002,"message":"gone"}}"#
        #expect(flushed([(.outbound, boolLoad), (.inbound, boolFailed)]) == [boolLoad, boolFailed])

        let agentRequest = #"{"jsonrpc":"2.0","id":1,"method":"fs/read_text_file","params":{}}"#
        let clientReply = #"{"jsonrpc":"2.0","id":1,"result":{"content":""}}"#
        #expect(flushed([
            (.outbound, load), (.inbound, agentRequest), (.outbound, clientReply), (.inbound, loadFailed)
        ]) == [agentRequest, clientReply])
        #expect(flushed([
            (.outbound, load), (.inbound, loadFailed), (.inbound, agentRequest), (.outbound, clientReply)
        ]) == [agentRequest, clientReply])

        // A load that succeeded, then a resume under the same id that failed: only the
        // failed pair goes.
        let loaded = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
        let resume = #"{"jsonrpc":"2.0","id":1,"method":"session/resume","params":{}}"#
        #expect(flushed([(.outbound, load), (.inbound, loaded), (.outbound, resume), (.inbound, loadFailed)])
            == [load, loaded])
        // An error once the load was answered is paired with nothing.
        #expect(flushed([(.outbound, load), (.inbound, loaded), (.inbound, loadFailed)]) == [load, loaded, loadFailed])
    }

    /// The history a `session/load` replays is the record's already, so acpx neither
    /// shows it nor records it — not even an update the agent sends straight after
    /// answering.
    @Test(.enabled(if: mockPythonAvailable))
    func theHistoryALoadReplaysIsNotShown() async throws {
        try await withLoggedMock(loadMode: "ok", replayOnLoad: true) { command, _ in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let record = try #require(SessionStore.loadRecord(id))
            let (shown, show) = AsyncStream<[WireMessageEvent]>.makeStream()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.ensure(
                recordId: id, agentCommand: record.agentCommand, cwd: record.cwd, mcpServers: nil,
                onConnectOutput: { show.yield($0) })
            show.finish()
            #expect(Self.methods(await shown.first { _ in true } ?? [])
                == ["initialize", "result", "session/load", "result"])

            _ = try await daemon.runPrompt(sessionId: id, text: "ping")
            let replies = try #require(SessionStore.loadRecord(id)).messages.flatMap { message -> [String] in
                guard case .agent(let agent) = message else { return [] }
                return agent.content.compactMap { if case .text(let text) = $0 { text } else { nil } }
            }
            #expect(!replies.isEmpty)
            #expect(!replies.joined().contains("replayed"))
        }
    }

    /// Connecting that fails still shows what it put on the wire, the agent's refusal
    /// included: acpx flushes its buffer on failure too.
    @Test(.enabled(if: mockPythonAvailable))
    func aFailedConnectShowsWhatItPutOnTheWire() async throws {
        try await withLoggedMock(loadMode: "internal") { command, _ in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            // A conversation worth keeping: the failed load is surfaced, not replaced.
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            let record = try #require(SessionStore.loadRecord(id))

            let (shown, show) = AsyncStream<[WireMessageEvent]>.makeStream()
            await #expect(throws: (any Error).self) {
                _ = try await ACPXDaemonBackend(inheritAgentStderr: false).ensure(
                    recordId: id, agentCommand: record.agentCommand, cwd: record.cwd, mcpServers: nil,
                    onConnectOutput: { show.yield($0) })
            }
            show.finish()
            #expect(Self.methods(await shown.first { _ in true } ?? [])
                == ["initialize", "result", "session/load", "error"])
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
