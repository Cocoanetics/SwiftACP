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
/// part of the turn, the answer is announced as it comes and the turn's end after it all,
/// and a cancel meanwhile finds its prompt answered.
extension DaemonToolsTests {
    /// The mock agent, holding a terminal of the turn open past its answer until `fifo` is
    /// written, logging the `session/*` requests it gets to `log`, and started with `options`.
    private static func holdingMock(_ fifo: URL, log: URL, _ options: String = "") throws -> String {
        let command = try #require(mockCommand())
        return "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_HOLD_TERMINAL='\(fifo.path)' MOCK_REQUEST_LOG='\(log.path)' "
            + "\(options) \(command)"
    }

    /// A stream that yields each time `client` is told a prompt was answered.
    private static func answers(to client: CallingClient) -> AsyncStream<Void> {
        let (answers, answered) = AsyncStream<Void>.makeStream()
        client.observe { log in
            if (try? log.decoded(TurnAnsweredEvent.self)) != nil { answered.yield() }
        }
        return answers
    }

    /// An update the agent sends 200 ms after answering reaches the calling client — after
    /// the answer, before the turn's end — and the record; a cancel asked while the turn
    /// waits for it is taken (`true`), and nothing is sent, as acpx's owner finds no
    /// active prompt then.
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
                let answered = client.logs.firstIndex { (try? $0.decoded(TurnAnsweredEvent.self)) != nil }
                let ended = client.logs.firstIndex { (try? $0.decoded(TurnEndedEvent.self)) != nil }
                let lateLog = client.logs.firstIndex { log in
                    guard let note = try? log.decoded(SessionNotification.self),
                          case .agentMessageChunk(let block) = note.update else { return false }
                    return block.text == "late"
                }
                #expect(try #require(answered) < #require(lateLog))
                #expect(try #require(lateLog) < #require(ended))
                let record = try #require(SessionStore.loadRecord(id))
                let agentText = record.messages.compactMap { message -> String? in
                    guard case .agent(let agent) = message else { return nil }
                    return agent.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
                }.joined()
                #expect(agentText.hasSuffix("late"))
            }
        }
    }

    /// A cancel from the moment the client learns the prompt was answered has nothing to
    /// send — though the turn still waits on a request the agent left open — as acpx's
    /// owner finds no active prompt once the answer is in. The cancel is taken, and the
    /// turn ends as it was answered.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCancelAfterTheAnswerSendsNothing() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (log, terminal) = (directory.appendingPathComponent("requests.log"), directory.appendingPathComponent("t"))
        #expect(mkfifo(terminal.path, 0o600) == 0)
        let command = try Self.holdingMock(terminal, log: log)
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let client = CallingClient()
            let answers = Self.answers(to: client)
            let turn = Task { try await prompt(daemon, id, text: "hi", client: client) }
            for await _ in answers { break }

            #expect(try await daemon.cancelSession(sessionId: id))
            // The terminal ends — and with it the turn — once its FIFO is written.
            close(await Self.openForWriting(terminal))
            try await turn.value

            #expect(!Self.requests(log).contains("session/cancel"))
            #expect(Self.stopReason(client) == "end_turn")
        }
    }

    /// How the turn's permissions went — which decides the CLI's exit code — is read at
    /// the turn's end, not at its answer: a question the agent asks after answering, while
    /// the turn still waits on a request it left open, counts, as acpx reads the stats for
    /// its result once the turn is over.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPermissionAskedAfterTheAnswerCounts() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (log, terminal) = (directory.appendingPathComponent("requests.log"), directory.appendingPathComponent("t"))
        let gate = directory.appendingPathComponent("gate")
        #expect(mkfifo(terminal.path, 0o600) == 0 && mkfifo(gate.path, 0o600) == 0)
        let command = try Self.holdingMock(terminal, log: log, "MOCK_ASK_AFTER_ANSWER='\(gate.path)'")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let client = CallingClient()
            let answers = Self.answers(to: client)
            let turn = Task { try await prompt(daemon, id, text: "hi", client: client) }
            for await _ in answers { break }

            // The agent asks once its gate opens — after the answer went out — and then
            // lets its terminal end.
            close(await Self.openForWriting(gate))
            try await turn.value

            let ended = try #require(client.logs.lazy.compactMap { try? $0.decoded(TurnEndedEvent.self) }.first)
            #expect(ended.permissions?.requested == 1)
            #expect(ended.permissions?.approved == 1)
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
            try JSONValue(encoding: chunk("early ")),
            try JSONValue(encoding: TurnAnsweredEvent(answeredStopReason: "end_turn")),
            try JSONValue(encoding: chunk("late")), try JSONValue(encoding: TurnEndedEvent(stopReason: "end_turn"))
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
