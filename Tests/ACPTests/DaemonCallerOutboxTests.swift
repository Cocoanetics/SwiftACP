@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import Logging
@testable import SwiftACP
import SwiftMCP
import Testing

/// What acpxd sends a call's client waits in the call's outbox, not in the turn, as acpx's queue
/// owner spools an observer's output (openclaw/acpx#723): a caller that reads nothing holds its
/// own call, not the session its turn ran on, and one past a bound is disconnected, as acpx
/// destroys that observer's socket.
extension DaemonToolsTests {
    /// A prompt, as acpxd serves it for a client on `transport`: its outbox bound, then flushed.
    static func served(
        _ daemon: ACPXDaemonBackend, _ sessionId: String, text: String, on transport: any Transport
    ) async throws -> String {
        let session = Session(id: UUID())
        await session.setTransport(transport)
        return try await session.work { _ in
            try await daemon.servingCall { try await daemon.runPrompt(sessionId: sessionId, text: text) }
        }
    }

    /// While its caller reads nothing, a turn ends and the next prompt on its session runs to its
    /// end; once the caller reads, it gets all of the turn, in order, its end last.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCallerThatReadsNothingHoldsOnlyItsCall() async throws {
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        try await withIsolatedStore {
            try await Self.withDaemon { daemon in
                let id = try await daemon.newSession(
                    agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
                let stopped = StoppedClient()
                defer { stopped.letThrough() }
                let first = Task { try await Self.served(daemon, id, text: "chunks 20 10", on: stopped) }
                await stopped.sendWaits()

                let next = CallingClient()
                _ = try await withTimeout(milliseconds: 20_000) {
                    try await Self.served(daemon, id, text: "hi", on: next)
                }
                #expect(next.logs.contains { (try? $0.decoded(TurnEndedEvent.self)) != nil })

                stopped.letThrough()
                let reply = try await withTimeout(milliseconds: 20_000) { try await first.value }
                #expect(reply == String(repeating: "x", count: 200))
                let kinds = stopped.kinds
                #expect(kinds == Array(repeating: "update", count: 20) + ["answered", "ended"], "\(kinds)")
            }
        }
    }

    /// A caller whose waiting output passes its call's bound is disconnected and sent nothing
    /// more; the turn goes on to its end all the same.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCallerPastItsBoundIsDisconnected() async throws {
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        try await withIsolatedStore {
            try await Self.withDaemon { daemon in
                let id = try await daemon.newSession(
                    agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
                let stopped = StoppedClient()
                defer { stopped.letThrough() }
                // 200 chunks of 1000 characters wait behind the first: past the call's 16 KiB.
                let limits = CallerOutbox.Limits(callBytes: 16 << 10)
                let reply = try await CallerOutbox.$limits.withValue(limits) {
                    try await withTimeout(milliseconds: 20_000) {
                        try await Self.served(daemon, id, text: "chunks 200 1000", on: stopped)
                    }
                }
                #expect(reply.count == 200_000, "the turn ended early")
                // The call ends only once its client is disconnected, so no result reaches the
                // client first, as though nothing of its output had been dropped.
                #expect(stopped.isDisconnected, "the call ended before its client was disconnected")
                #expect(stopped.sentCount <= 1)
                #expect(limits.budget.held == (0, 0))
            }
        }
    }

    /// Past the calls that may have output waiting, the next call's client is disconnected; the
    /// others go on and get all of theirs.
    @Test func pastTheCallsWithOutputWaitingTheNextIsDisconnected() async throws {
        let limits = CallerOutbox.Limits(calls: 1)
        let (first, second) = (StoppedClient(), StoppedClient())
        defer { first.letThrough(); second.letThrough() }
        let (firstOutbox, secondOutbox) = (await Self.outbox(on: first, limits), await Self.outbox(on: second, limits))
        for outbox in [firstOutbox, secondOutbox] {
            outbox.post(Self.log("one"))
            outbox.post(Self.log("two"))
        }
        #expect(!firstOutbox.isDropped && secondOutbox.isDropped)
        await secondOutbox.flush()
        #expect(second.isDisconnected, "the flush ended before the client was disconnected")
        first.letThrough()
        await firstOutbox.flush()
        #expect(first.sentCount == 2)
        #expect(limits.budget.held == (0, 0))
    }

    /// Past what all calls may have waiting, the call that would pass it has its client
    /// disconnected; one within it goes on.
    @Test func pastWhatAllCallsMayHaveWaitingTheNextIsDisconnected() async throws {
        let one = CallerOutbox.size(of: log(String(repeating: "x", count: 100)))
        let limits = CallerOutbox.Limits(totalBytes: one + one / 2)
        let (first, second) = (StoppedClient(), StoppedClient())
        defer { first.letThrough(); second.letThrough() }
        let (firstOutbox, secondOutbox) = (await Self.outbox(on: first, limits), await Self.outbox(on: second, limits))
        for outbox in [firstOutbox, secondOutbox] {
            outbox.post(Self.log("in flight"))
            outbox.post(Self.log(String(repeating: "x", count: 100)))
        }
        #expect(!firstOutbox.isDropped && secondOutbox.isDropped)
        try await withTimeout(milliseconds: 10_000) { await second.disconnected() }
        #expect(limits.budget.held.bytes == one)
    }

    /// What a noisy agent writes to stderr waits for a slow caller within the call's bound — not
    /// all of it, however much the agent writes (#219 review): past it, the caller is
    /// disconnected and the rest dropped, as acpx's owner destroys an observer's socket past its
    /// backlog (openclaw/acpx#723).
    @Test func agentStderrWaitsForASlowCallerWithinABound() async throws {
        let client = SlowClient()
        let session = Session(id: UUID())
        await session.setTransport(client)
        // Under what the relay's newest chunks alone come to: past it, whatever the relay dropped.
        let limits = CallerOutbox.Limits(callBytes: 8 << 10)
        let outbox = CallerOutbox(session: session, limits: limits)
        let relay = AgentStderrRelay()
        relay.attach(to: outbox, logger: "stderr")
        for _ in 0 ..< 2000 { relay.observer(Data("line\n".utf8)) }
        await relay.detach()
        #expect(outbox.isDropped, "the caller's output passed no bound")
        if outbox.isDropped { await client.disconnected() } else { client.letThrough() }
        await outbox.flush()
        #expect(client.sent <= 1, "\(client.sent) chunks went out past the bound")
        #expect(limits.budget.held == (0, 0))
    }

    /// What is below the client's log level takes no room: past the call's bound in messages the
    /// client would never be sent, it is not disconnected, and nothing is counted.
    @Test func whatTheClientsLevelSuppressesTakesNoRoom() async throws {
        let client = StoppedClient()
        defer { client.letThrough() }
        let session = Session(id: UUID())
        await session.setTransport(client)
        await session.setMinimumLogLevel(.warning)
        let limits = CallerOutbox.Limits(callBytes: 1 << 10)
        let outbox = CallerOutbox(session: session, minimumLevel: await session.minimumLogLevel, limits: limits)
        // A warning goes out, and waits for the client; the info behind it would wait too.
        outbox.post(LogMessage(level: .warning, data: .string("warning")))
        await client.sendWaits()
        for _ in 0 ..< 100 { outbox.post(Self.log(String(repeating: "x", count: 100))) }
        #expect(!outbox.isDropped)
        #expect(limits.budget.held == (0, 0))
        client.letThrough()
        await outbox.flush()
        #expect(client.sentCount == 1 && !client.isDisconnected)
    }

    /// However many wait, all go out, in order, once the client reads.
    @Test func manyWaitingGoOutInOrder() async throws {
        let client = StoppedClient()
        defer { client.letThrough() }
        let outbox = await Self.outbox(on: client, CallerOutbox.Limits())
        for index in 0 ..< 3000 { outbox.post(Self.log("\(index)")) }
        client.letThrough()
        await outbox.flush()
        #expect(client.texts == (0 ..< 3000).map { "\($0)" })
    }

    /// What is posted goes out as `Session.sendLogNotification` sends it: the same frame, byte for
    /// byte, and nothing below the client's log level.
    @Test func whatIsPostedGoesOutAsALogNotificationDoes() async throws {
        let (direct, posted) = (CallingClient(), CallingClient())
        let message = LogMessage(level: .info, logger: "session", data: .object(["text": .string("a/b ü")]))
        let session = Session(id: UUID())
        await session.setTransport(direct)
        await session.work { session in await session.sendLogNotification(message) }
        await session.setTransport(posted)
        let outbox = CallerOutbox(session: session)
        outbox.post(message)
        await outbox.flush()
        #expect(posted.sentData == direct.sentData && posted.sentData.count == 1)

        await session.setMinimumLogLevel(.warning)
        outbox.post(message)
        await outbox.flush()
        #expect(posted.sentData.count == 1, "a message below the client's level went out")
    }

    /// What is posted goes out as the client's session — which the TCP transport sends by —
    /// whatever task posts it.
    @Test func whatIsPostedGoesOutAsTheClientsSession() async throws {
        let client = SessionNotingClient()
        let session = Session(id: UUID())
        await session.setTransport(client)
        let outbox = CallerOutbox(session: session)
        await Task.detached { outbox.post(Self.log("from nowhere")) }.value
        await outbox.flush()
        let id = await session.id
        #expect(client.sentAs == [id])
    }

    private static func outbox(on client: StoppedClient, _ limits: CallerOutbox.Limits) async -> CallerOutbox {
        let session = Session(id: UUID())
        await session.setTransport(client)
        return CallerOutbox(session: session, limits: limits)
    }

    private static func log(_ text: String) -> LogMessage {
        LogMessage(level: .info, data: .string(text))
    }

    private func log(_ text: String) -> LogMessage {
        Self.log(text)
    }
}

/// A caller that reads nothing until let through: each send waits, as one to a client that has
/// stopped reading does. Disconnected, what waits goes, as a closed connection's sends end.
final class StoppedClient: Transport, @unchecked Sendable {
    let logger = Logger(label: "acpx.tests.stopped-client")
    private let gate = HoldGate()
    private let waiting = HoldGate()
    private let disconnection = HoldGate()
    private let lock = NSLock()
    private var sent: [Data] = []
    private var marked = false

    func start() async throws {}
    func run() async throws {}
    func stop() async throws {}

    func send(_ data: Data) async throws {
        waiting.open()
        await gate.wait()
        lock.withLock { sent.append(data) }
    }

    func disconnect(_ session: Session) async {
        disconnection.open()
        gate.open()
        // Marked a few hops on, so that whoever returned before the disconnect finished sees it
        // unmarked.
        for _ in 0 ..< 3 { await Task.yield() }
        lock.withLock { marked = true }
    }

    func letThrough() {
        gate.open()
    }

    /// Once a send waits for the client.
    func sendWaits() async {
        await waiting.wait()
    }

    /// Once the client is disconnected.
    func disconnected() async {
        await disconnection.wait()
    }

    var sentCount: Int { lock.withLock { sent.count } }

    /// Whether the disconnect has finished.
    var isDisconnected: Bool { lock.withLock { marked } }

    /// The text each message sent carried as its data.
    var texts: [String] {
        lock.withLock { sent }.compactMap { data in
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let fields) = message, case .object(let params)? = fields["params"],
                  case .string(let text)? = params["data"] else { return nil }
            return text
        }
    }

    /// What each message sent was: `update`, `answered`, `ended` — or `other`.
    var kinds: [String] {
        lock.withLock { sent }.map { data in
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let fields) = message, case .object(let params)? = fields["params"],
                  let log = params["data"] else { return "other" }
            if (try? log.decoded(TurnAnsweredEvent.self)) != nil { return "answered" }
            if (try? log.decoded(TurnEndedEvent.self)) != nil { return "ended" }
            if (try? log.decoded(SessionNotification.self)) != nil { return "update" }
            return "other"
        }
    }
}

private final class SlowClient: Transport, @unchecked Sendable {
    let logger = Logger(label: "acpx.tests.slow-client")
    private let gate = HoldGate()
    private let disconnection = HoldGate()
    private let lock = NSLock()
    private var count = 0

    func start() async throws {}
    func run() async throws {}
    func stop() async throws {}

    func send(_ data: Data) async throws {
        await gate.wait()
        lock.withLock { count += 1 }
    }

    func letThrough() {
        gate.open()
    }

    /// Disconnected: what waits to go out goes, as a send to a closed connection ends.
    func disconnect(_ session: Session) async {
        gate.open()
        disconnection.open()
    }

    /// Once the client is disconnected.
    func disconnected() async {
        await disconnection.wait()
    }

    var sent: Int { lock.withLock { count } }
}

/// A client that notes the session each message is sent as (``Session/current``).
private final class SessionNotingClient: Transport, @unchecked Sendable {
    let logger = Logger(label: "acpx.tests.session-noting-client")
    private let lock = NSLock()
    private var sessions: [UUID?] = []

    func start() async throws {}
    func run() async throws {}
    func stop() async throws {}

    func send(_ data: Data) async throws {
        let current = await Session.current?.id
        lock.withLock { sessions.append(current) }
    }

    var sentAs: [UUID?] { lock.withLock { sessions } }
}
