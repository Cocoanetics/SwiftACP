@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
@testable import SwiftACP
import SwiftMCP
import Testing

/// A daemon turn goes on past the agent's answer until the session's updates have gone
/// quiet, as acpx's queue owner's does (#124): what the agent sends after answering is
/// part of the turn, the answer is announced as it comes and the turn's end after it all,
/// and a cancel meanwhile finds its prompt answered.
extension DaemonToolsTests {
    /// The mock agent, holding a terminal of the turn open past its answer until `release`
    /// exists, logging the `session/*` requests it gets to `log`, and started with `options`.
    private static func holdingMock(_ release: URL, log: URL, _ options: String = "") throws -> String {
        let command = try #require(mockCommand())
        return "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_HOLD_TERMINAL='\(release.path)' MOCK_REQUEST_LOG='\(log.path)' "
            + "\(options) \(command)"
    }

    /// Create `file`, which the mock agent waits for.
    private static func create(_ file: URL) {
        FileManager.default.createFile(atPath: file.path, contents: nil)
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
        let (log, release) = (directory.appendingPathComponent("requests.log"), directory.appendingPathComponent("r"))
        // However the test ends, the agent's terminal does, and with it the turn.
        defer {
            Self.create(release)
            try? FileManager.default.removeItem(at: directory)
        }
        let command = try Self.holdingMock(release, log: log)
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let client = CallingClient()
            let answers = Self.answers(to: client)
            let turn = Task { try await prompt(daemon, id, text: "hi", client: client) }
            for await _ in answers { break }

            #expect(try await daemon.cancelSession(sessionId: id))
            // The terminal ends — and with it the turn — once its file is there.
            Self.create(release)
            try await turn.value

            #expect(!Self.requests(log).contains("session/cancel"))
            #expect(Self.stopReason(client) == "end_turn")
        }
    }

    /// A command the agent waits on after answering does not hold the turn: waiting for
    /// its exit is not a request the prompt owns, so the turn ends once its updates go
    /// quiet, as acpx's does (#130). The wait is answered when the command is done, and
    /// what the agent says then comes after the turn's end.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCommandWaitedOnAfterTheAnswerDoesNotHoldTheTurn() async throws {
        let directory = try Self.scratchDirectory()
        let (log, release) = (directory.appendingPathComponent("requests.log"), directory.appendingPathComponent("r"))
        defer {
            Self.create(release)
            try? FileManager.default.removeItem(at: directory)
        }
        let command = try Self.holdingMock(release, log: log, "MOCK_HOLD_TERMINAL_AFTER_ANSWER=1")
        try await withIsolatedStore {
            try await TurnReplyDrain.$current.withValue(ReplyDrain(idleMilliseconds: 300, timeoutMilliseconds: 5000)) {
                let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
                let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
                let client = CallingClient()
                // The turn ends while the command still runs: nothing releases it before.
                // A turn that waited for its exit would not return.
                try await prompt(daemon, id, text: "hi", client: client)
                let requests = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                Self.create(release)

                #expect(client.logs.contains { (try? $0.decoded(TurnEndedEvent.self)) != nil })
                // The agent had asked for the command's exit before the turn ended.
                #expect(client.logs.contains { log in
                    (try? log.decoded(InboundRequest.self))?.method == "terminal/wait_for_exit"
                }, "\(requests)")
            }
        }
    }

    /// A request the agent makes once the turn's updates have gone quiet, and that is
    /// answered before the turn looks for requests, still keeps the turn going: the agent
    /// has not had the answer yet, and what it says once it has is the turn's.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aRequestAnsweredBeforeTheTurnLooksStillKeepsIt() async throws {
        let directory = try Self.scratchDirectory()
        let (log, gate) = (directory.appendingPathComponent("requests.log"), directory.appendingPathComponent("gate"))
        defer {
            Self.create(gate)
            try? FileManager.default.removeItem(at: directory)
        }
        let command = try #require(mockCommand())
        let mock = "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_REQUEST_LOG='\(log.path)' "
            + "MOCK_REACT_AFTER_GATE='\(gate.path)' \(command)"
        try await withIsolatedStore {
            try await TurnReplyDrain.$current.withValue(.acpx) {
                let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
                let id = try await daemon.newSession(agentCommand: mock, cwd: NSTemporaryDirectory())
                let client = CallingClient()
                let (asked, ask) = AsyncStream<Void>.makeStream()
                client.observe { log in
                    if let request = try? log.decoded(InboundRequest.self),
                       request.method == "session/request_permission", request.failure == nil { ask.yield() }
                }
                let once = OnceFlag()
                // Once the updates first go quiet: the agent asks, and the turn looks only
                // once the question is answered — before the answer can reach the agent.
                await daemon.setAfterUpdateDrain { recordId in
                    guard once.claim() else { return }
                    Self.create(gate)
                    for await _ in asked { break }
                    if let (connection, sessionId) = await daemon.agentConnection(for: recordId) {
                        await connection.waitForRequestsAnswered(sessionId: sessionId)
                    }
                }

                try await prompt(daemon, id, text: "hi", client: client)

                let ended = client.logs.firstIndex { (try? $0.decoded(TurnEndedEvent.self)) != nil }
                let reaction = client.logs.firstIndex { log in
                    guard let note = try? log.decoded(SessionNotification.self),
                          case .agentMessageChunk(let block) = note.update else { return false }
                    return block.text == "reaction"
                }
                #expect(try #require(reaction) < #require(ended))
            }
        }
    }

    /// A request that came once the prompt had stopped waiting for requests, but before
    /// the turn first looked, and that is still open when the updates first go quiet, keeps
    /// the turn going too: the turn waits for it, and what the agent says once it has the
    /// answer is the turn's — though no request came since the turn looked.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aRequestOpenPastTheFirstQuietKeepsTheTurn() async throws {
        let directory = try Self.scratchDirectory()
        let (log, gate) = (directory.appendingPathComponent("requests.log"), directory.appendingPathComponent("gate"))
        defer {
            Self.create(gate)
            try? FileManager.default.removeItem(at: directory)
        }
        let command = try #require(mockCommand())
        let mock = "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_REQUEST_LOG='\(log.path)' "
            + "MOCK_REACT_AFTER_GATE='\(gate.path)' \(command)"
        try await withIsolatedStore {
            try await TurnReplyDrain.$current.withValue(.acpx) {
                let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
                let id = try await daemon.newSession(agentCommand: mock, cwd: NSTemporaryDirectory())
                let client = CallingClient()
                let (asked, ask) = AsyncStream<Void>.makeStream()
                client.observe { log in
                    if let request = try? log.decoded(InboundRequest.self),
                       request.method == "session/request_permission", request.failure == nil { ask.yield() }
                }
                // Past the answer, and before the turn looks: the agent asks, and the turn
                // looks once the question has come. The question is served only once the
                // turn waits for it.
                await daemon.setBeforeReplyDrain { recordId in
                    let (released, release) = AsyncStream<Void>.makeStream()
                    if let (connection, _) = await daemon.agentConnection(for: recordId) {
                        await connection.setBeforeServingRequest { for await _ in released { break } }
                        await connection.setOnRequestWait { _ in release.finish() }
                    }
                    Self.create(gate)
                    for await _ in asked { break }
                }

                try await prompt(daemon, id, text: "hi", client: client)

                let ended = client.logs.firstIndex { (try? $0.decoded(TurnEndedEvent.self)) != nil }
                let reaction = client.logs.firstIndex { log in
                    guard let note = try? log.decoded(SessionNotification.self),
                          case .agentMessageChunk(let block) = note.update else { return false }
                    return block.text == "reaction"
                }
                #expect(try #require(reaction) < #require(ended))
            }
        }
    }

    /// Whether `stream` yields within `limit`.
    private static func first(of stream: AsyncStream<Void>, within limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// How the turn's permissions went — which decides the CLI's exit code — is read at
    /// the turn's end, not at its answer: a question the agent asks after answering, while
    /// the turn waits for its updates to go quiet, counts, as acpx reads the stats for its
    /// result once the turn is over.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPermissionAskedAfterTheAnswerCounts() async throws {
        let directory = try Self.scratchDirectory()
        let (log, release) = (directory.appendingPathComponent("requests.log"), directory.appendingPathComponent("r"))
        let gate = directory.appendingPathComponent("gate")
        defer {
            Self.create(gate)
            Self.create(release)
            try? FileManager.default.removeItem(at: directory)
        }
        let command = try Self.holdingMock(release, log: log, "MOCK_ASK_AFTER_ANSWER='\(gate.path)'")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let client = CallingClient()
            let (asked, ask) = AsyncStream<Void>.makeStream()
            client.observe { log in
                if let request = try? log.decoded(InboundRequest.self),
                   request.method == "session/request_permission", request.failure == nil { ask.yield() }
            }
            let once = OnceFlag()
            // Once the updates first go quiet, past the answer: the agent asks, and the turn
            // looks only once the question has come.
            await daemon.setAfterUpdateDrain { _ in
                guard once.claim() else { return }
                Self.create(gate)
                for await _ in asked { break }
            }

            try await prompt(daemon, id, text: "hi", client: client)

            let ended = try #require(client.logs.lazy.compactMap { try? $0.decoded(TurnEndedEvent.self) }.first)
            #expect(ended.permissions?.requested == 1)
            #expect(ended.permissions?.approved == 1)
        }
    }
}

/// True the first time it is claimed, false after.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

extension ACPXDaemonBackend {
    func setAfterUpdateDrain(_ hook: (@Sendable (_ recordId: String) async -> Void)?) {
        afterUpdateDrain = hook
    }

    func setBeforeReplyDrain(_ hook: (@Sendable (_ recordId: String) async -> Void)?) {
        beforeReplyDrain = hook
    }

    /// The connection and ACP session of the agent this daemon holds for `recordId`.
    func agentConnection(for recordId: String) -> (ACPAgentConnection, SessionId)? {
        live[recordId].map { ($0.agent.connection, $0.session.id) }
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

extension ACPAgentConnection {
    func setBeforeServingRequest(_ hook: (@Sendable () async -> Void)?) {
        beforeServingRequest = hook
    }

    /// Run `hook` when a wait for the agent's requests has to wait.
    func setOnRequestWait(_ hook: (@Sendable (SessionId) -> Void)?) {
        inboundRequests.setOnWait(hook)
    }
}
