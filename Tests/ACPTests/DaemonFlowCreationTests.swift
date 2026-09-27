@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A flow's session as acpxd makes it (#202, step 3b, #219 review): called off as it is made
/// — its caller's wait cut short, however the call-off and the creation cross, and however
/// long either waits — and made under an id acpxd holds already.
extension DaemonToolsTests {
    /// A session called off as acpxd makes it is let go, as acpx's runner closes a client made
    /// after its attempt stopped: whether its token was called off before it was made, the
    /// call-off came once it was made, or its call was cancelled as its agent was held — a
    /// caller whose wait was cut short never learns the session to let it go (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionCalledOffAsItIsMadeIsLetGo() async throws {
        let command = try #require(mockCommand())
        let cwd = NSTemporaryDirectory()
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(try await daemon.callOffCreation(creationToken: "before") == false)
            await #expect(throws: CancellationError.self) {
                _ = try await daemon.newSession(
                    agentCommand: command, agentArgv: nil, cwd: cwd, name: nil, mcpServers: nil, sessionOptions: nil,
                    creation: SessionCreationMode(holdAgent: true, creationToken: "before"))
            }
            #expect(await daemon.live.isEmpty)
            let made = try await daemon.newSession(
                agentCommand: command, agentArgv: nil, cwd: cwd, name: nil, mcpServers: nil, sessionOptions: nil,
                creation: SessionCreationMode(holdAgent: true, creationToken: "after"))
            #expect(try await daemon.callOffCreation(creationToken: "after"))
            #expect(await !daemon.sessionStatus(sessionId: made).live)
            // The call cancelled as its agent is held, from within its own task.
            await daemon.setReconnected { _ in withUnsafeCurrentTask { $0?.cancel() } }
            let creating = Task {
                try await daemon.newSession(
                    agentCommand: command, agentArgv: nil, cwd: cwd, name: nil, mcpServers: nil, sessionOptions: nil,
                    creation: SessionCreationMode(holdAgent: true))
            }
            await #expect(throws: CancellationError.self) { _ = try await creating.value }
            #expect(await daemon.live.isEmpty)
            await daemon.releaseAll()
        }
    }

    /// A call-off whose creation never came goes after a minute: each creation prunes those older,
    /// so a long-lived daemon doesn't keep them (#219 review). What a creation made stays, however
    /// long, until its agent is let go.
    @Test func callOffsKeptAMinuteAreLetGo() async throws {
        let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
        #expect(try await daemon.callOffCreation(creationToken: "called-off") == false)
        #expect(await daemon.creationCalledOff("made", madeAs: "a", agent: StandInAgent()) == false)
        let later = Date(timeIntervalSinceNow: 61)
        #expect(await daemon.creationCalledOff("later", madeAs: "b", agent: StandInAgent(), now: later) == false)
        #expect(await daemon.calledOffCreations.isEmpty)
        #expect(await daemon.madeCreations.keys.sorted() == ["later", "made"])
    }

    /// A call-off stays while its creation is under way, however long the agent takes: one that
    /// finishes past the minute the other tokens are kept still finds it, and its session is let
    /// go (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCallOffOutlastsASlowCreation() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let (reached, goOn) = (HoldGate(), HoldGate())
            // The session made, the creation waits as its agent is held.
            await daemon.setReconnected { _ in
                reached.open()
                await goOn.wait()
            }
            let creating = Task {
                try await daemon.newSession(
                    agentCommand: command, agentArgv: nil, cwd: NSTemporaryDirectory(), name: nil, mcpServers: nil,
                    sessionOptions: nil, creation: SessionCreationMode(holdAgent: true, creationToken: "slow"))
            }
            await reached.wait()
            let released = try await daemon.callOffCreation(creationToken: "slow")
            #expect(!released)
            // A creation a minute on prunes what is kept, but not the call-off of one under way.
            let later = Date(timeIntervalSinceNow: 61)
            #expect(await daemon.creationCalledOff("other", madeAs: "x", agent: StandInAgent(), now: later) == false)
            goOn.open()
            await #expect(throws: CancellationError.self) { _ = try await creating.value }
            #expect(await daemon.live.isEmpty)
            await daemon.releaseAll()
        }
    }

    /// A session the agent gives an id acpxd holds already takes that one's place, as `sessions
    /// new` retires one it replaces under the same id: the agent held before is let go, not left
    /// running unheld, and the record is the new session's (#219 review). The mock answers every
    /// launch with the same session id.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionUnderAHeldIdTakesItsPlace() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let cwd = NSTemporaryDirectory()
            let first = try await daemon.newSession(agentCommand: command, cwd: cwd, holdAgent: true)
            let before = try #require(await daemon.live[first]?.agent)
            let second = try await daemon.newSession(agentCommand: command, cwd: cwd, holdAgent: true)
            #expect(second == first)
            let after = try #require(await daemon.live[second]?.agent)
            #expect(after !== before)
            #expect(await before.connection.isClosed)
            #expect(SessionStore.loadRecord(second)?.pid == after.lifecycle?.pid.map { Int($0) })
            await daemon.releaseAll()
        }
    }

    /// A creation called off before its agent is held takes nobody's place under the id it was
    /// given: another flow's session held there stays, its agent untouched, and the creation's
    /// own agent goes (#219 review). The mock gives every session the same id.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCalledOffCreationTakesNobodysPlace() async throws {
        let command = try #require(mockCommand())
        let cwd = NSTemporaryDirectory()
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: cwd, holdAgent: true)
            let kept = try #require(await daemon.live[id]?.agent)
            let record = try #require(SessionStore.loadRecord(id))
            let released = try await daemon.callOffCreation(creationToken: "stopped")
            #expect(!released)
            await #expect(throws: CancellationError.self) {
                _ = try await daemon.newSession(
                    agentCommand: command, agentArgv: nil, cwd: cwd, name: nil, mcpServers: nil, sessionOptions: nil,
                    creation: SessionCreationMode(holdAgent: true, creationToken: "stopped"))
            }
            #expect(await daemon.live[id]?.agent === kept)
            #expect(await !kept.connection.isClosed)
            // Its record too: the called-off creation's never replaced it.
            #expect(SessionStore.loadRecord(id)?.pid == record.pid)
            #expect(SessionStore.loadRecord(id)?.createdAt == record.createdAt)
            await daemon.releaseAll()
        }
    }

    /// A creation called off while it waits for the slot of the session held under its id — that
    /// session's turn running — takes nobody's place either, once the turn is over (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCreationCalledOffAsItWaitsTakesNobodysPlace() async throws {
        let command = try #require(mockCommand())
        let cwd = NSTemporaryDirectory()
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: cwd)
            let (turnGoesOut, creationWaits) = (HoldGate(), HoldGate())
            await daemon.setPromptGoingOut { _ in turnGoesOut.open() }
            let turn = Task {
                try await daemon.runPrompt(sessionId: id, text: "hold turn", permissionMode: "approve-all")
            }
            await turnGoesOut.wait()
            let kept = try #require(await daemon.live[id]?.agent)
            await daemon.turnQueue.setBeforeAcquire { _ in creationWaits.open() }
            let creating = Task {
                try await daemon.newSession(
                    agentCommand: command, agentArgv: nil, cwd: cwd, name: nil, mcpServers: nil, sessionOptions: nil,
                    creation: SessionCreationMode(holdAgent: true, creationToken: "late"))
            }
            await creationWaits.wait()
            let released = try await daemon.callOffCreation(creationToken: "late")
            #expect(!released)
            #expect(try await daemon.cancelSession(sessionId: id))
            _ = try? await turn.value
            await #expect(throws: CancellationError.self) { _ = try await creating.value }
            #expect(await daemon.live[id]?.agent === kept)
            #expect(await !kept.connection.isClosed)
            await daemon.releaseAll()
        }
    }

    /// A call-off lets go of the agent its creation made, and only that one: a session the
    /// agent gave the same id since, which took its place, keeps its agent (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCallOffLetsGoOnlyOfTheAgentItsCreationMade() async throws {
        let command = try #require(mockCommand())
        let cwd = NSTemporaryDirectory()
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, agentArgv: nil, cwd: cwd, name: nil, mcpServers: nil, sessionOptions: nil,
                creation: SessionCreationMode(holdAgent: true, creationToken: "first"))
            let replaced = try await daemon.newSession(
                agentCommand: command, agentArgv: nil, cwd: cwd, name: nil, mcpServers: nil, sessionOptions: nil,
                creation: SessionCreationMode(holdAgent: true, creationToken: "second"))
            #expect(replaced == id)
            let kept = try #require(await daemon.live[id]?.agent)
            // The first creation's agent went as the second took its place: nothing of it is kept.
            #expect(await daemon.madeCreations["first"] == nil)
            let releasedTheFirst = try await daemon.callOffCreation(creationToken: "first")
            #expect(!releasedTheFirst)
            #expect(await daemon.live[id]?.agent === kept)
            #expect(await !kept.connection.isClosed)
            #expect(try await daemon.callOffCreation(creationToken: "second"))
            #expect(await daemon.live.isEmpty)
            await daemon.releaseAll()
        }
    }

    /// A session made under an id acpxd holds takes its place once the turn running there is
    /// over, and the prompts meant for the old session are refused — one begun as that turn
    /// ended, one still in line — never run on the new session's agent (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func thePromptsOfAReplacedSessionAreRefused() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = directory.appendingPathComponent("requests.log")
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_REQUEST_LOG='\(requests.path)' "
            + (try #require(mockCommand()))
        let cwd = NSTemporaryDirectory()
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: cwd)
            let prompt = { (text: String) in
                Task { try await daemon.runPrompt(sessionId: id, text: text, permissionMode: "approve-all") }
            }
            let (running, secondWaits, thirdWaits, creationWaits) = (HoldGate(), HoldGate(), HoldGate(), HoldGate())
            await daemon.setPromptGoingOut { _ in running.open() }
            let first = prompt("hold turn")
            await running.wait()
            await daemon.setPromptWaits { _ in secondWaits.open() }
            let second = prompt("second")
            await secondWaits.wait()
            await daemon.setPromptWaits { _ in thirdWaits.open() }
            let third = prompt("third")
            await thirdWaits.wait()
            await daemon.turnQueue.setBeforeAcquire { _ in creationWaits.open() }
            let creating = Task { try await daemon.newSession(agentCommand: command, cwd: cwd, holdAgent: true) }
            await creationWaits.wait()
            #expect(try await daemon.cancelSession(sessionId: id))
            _ = try? await first.value
            #expect(try await creating.value == id)
            await #expect(throws: QueueOwnerShuttingDown.self) { _ = try await second.value }
            await #expect(throws: QueueOwnerShuttingDown.self) { _ = try await third.value }
            let logged = (try? String(contentsOf: requests, encoding: .utf8)) ?? ""
            #expect(!logged.contains("second") && !logged.contains("third"), "\(logged)")
            await daemon.releaseAll()
        }
    }

    /// A creation cancelled as its session is held lets go of its own agent, and no other: one
    /// that took its place under the same id meanwhile keeps its agent (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCancelledCreationLetsGoOnlyOfItsOwnAgent() async throws {
        let command = try #require(mockCommand())
        let cwd = NSTemporaryDirectory()
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let (firstKept, secondKept, calls) = (HoldGate(), HoldGate(), CallCount())
            // Held, the first creation is cancelled, and waits until the second has taken its place.
            await daemon.setCreationKept { _ in
                guard calls.next() == 1 else { return secondKept.open() }
                withUnsafeCurrentTask { $0?.cancel() }
                firstKept.open()
                await secondKept.wait()
            }
            let first = Task { try await daemon.newSession(agentCommand: command, cwd: cwd, holdAgent: true) }
            await firstKept.wait()
            let second = try await daemon.newSession(agentCommand: command, cwd: cwd, holdAgent: true)
            await #expect(throws: CancellationError.self) { _ = try await first.value }
            let kept = try #require(await daemon.live[second]?.agent)
            #expect(await !kept.connection.isClosed)
            await daemon.releaseAll()
        }
    }

    /// The release a stopped turn forces past its grace puts down the agent that turn runs on,
    /// while it runs, and nothing else: named for a turn the session no longer runs, it leaves
    /// the session as it is, for what came since (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aForcedReleaseReachesOnlyItsOwnTurn() async throws {
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let running = HoldGate()
            await daemon.setPromptGoingOut { _ in running.open() }
            let turn = Task {
                try await daemon.runPrompt(
                    sessionId: id, text: "hold turn", permissionMode: "approve-all", direct: true, turnToken: "now")
            }
            await running.wait()
            let agent = try #require(await daemon.live[id]?.agent)
            let releasedAnother = try await daemon.releaseSession(sessionId: id, turnToken: "gone")
            #expect(!releasedAnother)
            #expect(await !agent.connection.isClosed)
            #expect(try await daemon.releaseSession(sessionId: id, turnToken: "now"))
            await #expect(throws: (any Error).self) { _ = try await turn.value }
            #expect(await agent.connection.isClosed)
            await daemon.releaseAll()
        }
    }

    /// A session made to be let go at once has its record written once its agent is gone, and
    /// not before: nothing reads a record whose pid is on its way out, or saves to one the write
    /// after the close would go over (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionLetGoAtOnceIsRecordedOnceItsAgentIsGone() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let seen = Lines()
            let look: @Sendable (String) -> Void = {
                seen.add(SessionStore.loadRecord($0) == nil ? "absent" : "present")
            }
            let made = try await SessionEngine.$beforeClosing.withValue(look) {
                try await SessionEngine.createSession(
                    agentCommand: command, cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll,
                    authCredentials: [:], authPolicy: "skip")
            }
            #expect(seen.all == ["absent"])
            #expect(SessionStore.loadRecord(made.acpxRecordId)?.pid == nil)
        }
    }

    /// A call-off stays while its turn waits to begin behind another, however long: begun past
    /// the minute other call-offs are kept, the turn still ends at once, nothing sent (#219
    /// review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCallOffOutlastsATurnWaitingToBegin() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = directory.appendingPathComponent("requests.log")
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_REQUEST_LOG='\(requests.path)' "
            + (try #require(mockCommand()))
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
            let (firstGoesOut, secondWaits) = (HoldGate(), HoldGate())
            await daemon.setPromptGoingOut { _ in firstGoesOut.open() }
            await daemon.setPromptWaits { _ in secondWaits.open() }
            let first = Task {
                try await daemon.runPrompt(
                    sessionId: id, text: "hold turn", permissionMode: "approve-all", direct: true)
            }
            await firstGoesOut.wait()
            let second = Task {
                try await daemon.runPrompt(
                    sessionId: id, text: "second", permissionMode: "approve-all", direct: true, turnToken: "queued")
            }
            await secondWaits.wait()
            let cancelledTheFirst = try await daemon.cancelSession(sessionId: id, turnToken: "queued")
            #expect(!cancelledTheFirst)
            // A call-off a minute on prunes what is kept: not the call-off of a turn still waiting.
            await daemon.callOff("other", now: Date(timeIntervalSinceNow: 61))
            // The first turn ends cancelled; the second begins, and ends at once.
            #expect(try await daemon.cancelSession(sessionId: id))
            _ = try? await first.value
            #expect(try await second.value.isEmpty)
            let logged = (try? String(contentsOf: requests, encoding: .utf8)) ?? ""
            #expect(!logged.contains("\"second\""), "\(logged)")
            await daemon.releaseAll()
        }
    }
}

/// A signal a test waits for once, however it and its opening cross.
private final class HoldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// Stands in, by its identity, for the agent a creation made.
private final class StandInAgent: Sendable {}

/// How often a test's hook has run.
private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// The call this is: 1 for the first.
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

extension ACPXDaemonBackend {
    func setCreationKept(_ hook: (@Sendable (_ recordId: String) async -> Void)?) {
        creationKept = hook
    }
}
