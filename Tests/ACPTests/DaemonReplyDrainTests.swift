@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// A daemon turn goes on past the agent's answer until the session's updates have gone
/// quiet, as acpx's queue owner's does (#124): what the agent sends after answering is
/// part of the turn, the turn's end goes out at the answer, and a cancel meanwhile finds
/// its prompt answered.
extension DaemonToolsTests {
    /// An update the agent sends 200 ms after answering reaches the calling client — after
    /// the turn's end, which goes out at the answer — and the record; a cancel asked while
    /// the turn waits for it is taken (`true`), and nothing is sent, as acpx's owner finds
    /// no active prompt then.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anUpdateAfterTheAnswerIsPartOfTheTurn() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("drain-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let command = try #require(mockCommand())
        let late = "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_LATE_CHUNK=late MOCK_REQUEST_LOG='\(log.path)' \(command)"
        try await withIsolatedStore {
            try await TurnReplyDrain.$current.withValue(.acpx) {
                let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
                let id = try await daemon.newSession(agentCommand: late, cwd: NSTemporaryDirectory())
                let client = CallingClient()
                let (lateSeen, seen) = AsyncStream<Void>.makeStream()
                client.observe { log in
                    guard let note = try? log.decoded(SessionNotification.self),
                          case .agentMessageChunk(let block) = note.update, block.text == "late"
                    else { return }
                    seen.yield()
                }
                let turn = Task { try await prompt(daemon, id, text: "hi", client: client) }
                for await _ in lateSeen { break }
                #expect(try await daemon.cancelSession(sessionId: id))
                try await turn.value
                let requests = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                #expect(!requests.contains("session/cancel"))
                let ended = client.logs.firstIndex { (try? $0.decoded(TurnEndedEvent.self)) != nil }
                let lateLog = client.logs.firstIndex { log in
                    guard let note = try? log.decoded(SessionNotification.self),
                          case .agentMessageChunk(let block) = note.update else { return false }
                    return block.text == "late"
                }
                #expect(try #require(ended) < #require(lateLog))
                let record = try #require(SessionStore.loadRecord(id))
                let agentText = record.messages.compactMap { message -> String? in
                    guard case .agent(let agent) = message else { return nil }
                    return agent.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
                }.joined()
                #expect(agentText.hasSuffix("late"))
            }
        }
    }
}

/// How `prompt` renders an update that comes after the turn's end, as acpx's formatters
/// do (#124): text output after `[done]`, quiet output not at all.
struct LateUpdateRenderingTests {
    private static func rendered(_ format: OutputFormat, thenFailing: Bool = false) async throws -> String {
        let out = OutputRendererTests.Capture()
        let renderer = OutputRenderer(
            options: RenderOptions(format: format), out: out.write, err: { _ in }, color: false)
        let logs = PromptLogRenderer(renderer, stopReason: StopReasonBox())
        // Never connected: the handler only needs it to be called with.
        let proxy = MCPServerProxy(config: .stdioHandles(server: ACPXDaemon(backend: ACPXDaemonBackend())))
        let chunk = { (text: String) in
            SessionNotification(sessionId: "s", update: .agentMessageChunk(.text(text)))
        }
        for data in [
            try JSONValue(encoding: chunk("early ")), try JSONValue(encoding: TurnEndedEvent(stopReason: "end_turn")),
            try JSONValue(encoding: chunk("late"))
        ] {
            await logs.mcpServerProxy(proxy, didReceiveLog: LogMessage(level: .info, logger: "s", data: data))
        }
        // A failure flushes what quiet output holds back — none of which came after the end.
        if thenFailing { renderer.turnFailed(TurnFailure.event(for: POSIXError(.EIO), shown: nil, sessionId: "s")) }
        renderer.finish(stopReason: .endTurn)
        return out.text
    }

    @Test func textShowsWhatComesAfterTheEnd() async throws {
        let text = try await Self.rendered(.text)
        let (done, late) = (try #require(text.range(of: "[done] end_turn")), try #require(text.range(of: "late")))
        #expect(done.upperBound <= late.lowerBound)
        #expect(text.components(separatedBy: "[done]").count == 2)
    }

    @Test func quietShowsNothingAfterTheEnd() async throws {
        #expect(try await Self.rendered(.quiet) == "early \n")
        #expect(try await Self.rendered(.quiet, thenFailing: true) == "early \n")
    }
}
