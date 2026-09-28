@testable import ACPXCore
@testable import acpxd
import Foundation
@testable import SwiftACP
import Testing

/// An acpxd started on demand stops by itself once it has held nothing and served nothing for a
/// while, as acpx's queue owner exits after its TTL (#253).
struct IdleExitTests {
    @Test func idlenessCountsFromWhenItWasFirstSeenAndWorkStartsItAnew() {
        var tracker = IdleExit.Tracker(grace: .seconds(10))
        let start = ContinuousClock.now
        let looks: [(idle: Bool, after: Duration)] = [
            (true, .zero), (true, .seconds(9)), (false, .milliseconds(9_500)), (true, .seconds(10)),
            (true, .seconds(19)), (true, .seconds(20))
        ]
        let stops = looks.map { tracker.observe(idle: $0.idle, at: start + $0.after) }
        #expect(stops == [false, false, false, false, false, true])
    }

    /// Once the daemon has been idle for the grace, the watch stops it — and should it have found
    /// work meanwhile, waits for it to be idle for the grace again.
    @Test(.timeLimit(.minutes(1)))
    func theWatchStopsTheDaemonOnceIdleUnlessItFoundWork() async {
        let asks = StopAsks()
        let watch = IdleExit.watch(grace: .milliseconds(20), interval: .milliseconds(5), isIdle: { true }, stop: {
            await asks.ask()
        })
        await watch.value
        #expect(await asks.count == 2)
    }
}

/// The daemon decides whether it stops in one step with taking calls (Codex review on #289).
extension IdleExitTests {
    /// Once it stops, it takes no call: each is refused as acpx's owner refuses one once it shuts
    /// down, and none is counted.
    @Test func aDaemonThatStoppedTakesNoMoreCalls() async throws {
        try await withIsolatedStore {
            let daemon = ACPXDaemon(backend: ACPXDaemonBackend(inheritAgentStderr: false))
            #expect(await daemon.stopTakingCallsIfIdle { true })
            let refusal = await #expect(throws: DescribedToolFailure.self) { _ = try await daemon.listSessions() }
            #expect(refusal?.failure == StoppedTakingCalls.failure)
            #expect(refusal?.localizedDescription == "Queue owner is shutting down")
            #expect(await daemon.callsInFlight == 0)
            #expect(await !daemon.stopTakingCallsIfIdle { true })
        }
    }

    /// A daemon serving a call does not stop, whatever the backend says.
    @Test func aDaemonServingACallDoesNotStop() async throws {
        try await withIsolatedStore {
            let daemon = ACPXDaemon(backend: ACPXDaemonBackend(inheritAgentStderr: false))
            let stopped = try await daemon.serving { await daemon.stopTakingCallsIfIdle { true } }
            #expect(!stopped)
            #expect(try await daemon.listSessions().isEmpty)
        }
    }

    /// A call that comes while the daemon decides waits for the answer: served should it go on,
    /// refused once it stops — never run under a daemon that has let its lock go.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aCallWhileTheDaemonDecidesWaitsForTheAnswer(stops: Bool) async throws {
        try await withIsolatedStore {
            let daemon = ACPXDaemon(backend: ACPXDaemonBackend(inheritAgentStderr: false))
            let (waits, waiting) = AsyncStream<Void>.makeStream()
            await daemon.observeWaits { waiting.yield() }
            let call = CallBox()
            let stopped = await daemon.stopTakingCallsIfIdle {
                call.start { try await daemon.listSessions() }
                var waited = waits.makeAsyncIterator()
                _ = await waited.next()
                return stops
            }
            #expect(stopped == stops)
            let result = try #require(await call.result())
            switch result {
            case .success(let sessions): #expect(!stops && sessions.isEmpty)
            case .failure(let error): #expect(stops && error.localizedDescription == "Queue owner is shutting down")
            }
        }
    }
}

/// A call started inside a daemon's decision, and how it ended.
private final class CallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<[SessionSummary], Error>?

    func start(_ body: @escaping @Sendable () async throws -> [SessionSummary]) {
        lock.withLock { task = Task { try await body() } }
    }

    func result() async -> Result<[SessionSummary], Error>? {
        await lock.withLock { task }?.result
    }
}

/// Stops asked for: the first is refused, as by a daemon that found work meanwhile.
private actor StopAsks {
    private(set) var count = 0

    func ask() -> Bool {
        count += 1
        return count > 1
    }
}

extension DaemonToolsTests {
    /// A daemon started on demand stops only once it holds no session: not while an owner holds
    /// one, as acpx's owner lives until its TTL. Once it stops, it starts nothing more — a prompt
    /// is refused as acpx's owner refuses one as it shuts down — and its lock is given up at
    /// once, for the daemon a CLI starts next.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anIdleDaemonStopsOnlyOnceItHoldsNoSession() async throws {
        let command = try #require(mockCommand())
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let lock = DaemonLock(url: directory.appendingPathComponent("acpxd.lock"))
            #expect(try lock.acquire())
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false, lock: lock)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            #expect(await daemon.holdsNothing())

            _ = try await daemon.runPrompt(sessionId: id, text: "hi")
            #expect(await !daemon.holdsNothing())
            #expect(await !daemon.stopIfHoldingNothing())
            #expect(await !daemon.stopping)
            #expect(lock.currentHolder()?.pid == getpid())

            #expect(try await daemon.releaseSession(sessionId: id))
            #expect(await daemon.holdsNothing())
            #expect(await daemon.stopIfHoldingNothing())
            #expect(await daemon.stopping)
            #expect(lock.currentHolder() == nil)
            await #expect(throws: QueueOwnerShuttingDown(inLine: false)) {
                _ = try await daemon.runPrompt(sessionId: id, text: "again")
            }
            await daemon.releaseAll()
        }
    }

    /// A call counts among those the daemon serves until its work is over
    /// (``ACPXDaemon/callsInFlight``): an idle daemon never stops under a call.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCallCountsWhileTheDaemonServesIt() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("stall-prompt")
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let daemon = ACPXDaemon(backend: backend)
            let (out, goesOut) = AsyncStream<Void>.makeStream()
            await backend.setPromptGoingOut { _ in goesOut.yield() }
            #expect(await daemon.callsInFlight == 0)

            let prompt = Task { try await daemon.runPrompt(sessionId: session.id, text: "hi") }
            var goingOut = out.makeAsyncIterator()
            _ = await goingOut.next()
            #expect(await daemon.callsInFlight == 1)
            #expect(await !backend.holdsNothing())

            _ = try await backend.cancelSession(sessionId: session.id)
            _ = try? await prompt.value
            #expect(await daemon.callsInFlight == 0)
            await backend.releaseAll()
        }
    }
}
