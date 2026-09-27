@testable import ACPXCore
@testable import ACPXFlows
@testable import acpx
@testable import acpxd
import Foundation
@testable import SwiftACP
import SwiftMCP
import Testing

/// The flow CLI's side of a persistent session, as its creation meets what can go wrong
/// around it (#202, step 3b, #219 review): a daemon still starting as the flow stops, and a
/// record that cannot be read once the session is made.
extension DaemonToolsTests {
    /// A persistent session whose record the CLI cannot read once acpxd made it is let go: it
    /// is never the run's, so nothing else would (#219 review). Here the record is gone by then.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionWhoseRecordCannotBeReadIsLetGo() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let config = try ConfigLoader.load(cwd: NSTemporaryDirectory())
            let sessions = FlowAgentSessions(
                flags: try Flags.resolveGlobalFlags(ScannedArgs(), config: config), config: config,
                permission: .approveAll, permissionRules: nil, mcpServers: [])
            let attempt = FlowAttempt(nodeId: "ask", attemptId: "ask-1", startedAt: nowISO(), timeoutMs: nil)
            let agent = FlowAgent(agentName: "mock", agentCommand: command, agentArgv: nil, cwd: NSTemporaryDirectory())
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            let removeTheRecord: @Sendable (String) -> Void = {
                try? FileManager.default.removeItem(at: ACPXPaths.sessionRecordPath($0))
            }
            await #expect(throws: CLIError.self) {
                try await DaemonClient.$standIn.withValue(daemon) {
                    try await FlowAgentSessions.$afterCreating.withValue(removeTheRecord) {
                        _ = try await sessions.createPersistent(
                            agent: agent, name: "flow-main", control: FlowTurnControl(attempt: attempt))
                    }
                }
            }
            #expect(await backend.live.isEmpty)
        }
    }

    /// A flow stopped while its CLI waits for a daemon still starting stops at once, with why:
    /// the wait is cut short, as acpx's signal aborts its client's start — well within the ~9 s
    /// the CLI gives a daemon to come up, which this one never does (#219 review).
    @Test(.timeLimit(.minutes(1)))
    func reachingADaemonStopsWithTheFlow() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        #expect(mkfifo(started.path, 0o600) == 0)
        let daemon = directory.appendingPathComponent("daemon.sh")
        try "#!/bin/sh\nprintf up > '\(started.path)'\nexec sleep 20\n"
            .write(to: daemon, atomically: true, encoding: .utf8)
        #expect(chmod(daemon.path, 0o755) == 0)
        try await withIsolatedStore {
            let attempt = FlowAttempt(nodeId: "ask", attemptId: "ask-1", startedAt: nowISO(), timeoutMs: nil)
            let control = FlowTurnControl(attempt: attempt)
            let reaching = Task {
                try await FlowAgentSessions.connect(until: control, daemonExecutable: daemon.path) { _ in }
            }
            // Once the daemon has started, and is waited for, the flow stops.
            await Self.waitForWrite(to: started)
            let stopped = ContinuousClock.now
            attempt.cancel(FlowTimeoutError(timeoutMs: 10))
            await #expect(throws: FlowTimeoutError.self) { _ = try await reaching.value }
            #expect(ContinuousClock.now - stopped < .seconds(5))
        }
    }

    /// A direct turn called off as it has the session's slot, before anything is sent, lets its
    /// agent go too, as acpx's direct turn closes the client it was handed however it ends — a
    /// caller of the direct tool has nothing else to let it go (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnCancelledAsItBeginsLetsItsAgentGo() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
            #expect(await daemon.sessionStatus(sessionId: id).live)
            // The turn is cancelled from within, as it takes the slot.
            await daemon.turnQueue.setBeforeAcquire { _ in withUnsafeCurrentTask { $0?.cancel() } }
            let turn = Task {
                try await daemon.runPrompt(sessionId: id, text: "hi", permissionMode: "approve-all", direct: true)
            }
            await #expect(throws: CancellationError.self) { _ = try await turn.value }
            #expect(await !daemon.sessionStatus(sessionId: id).live)
            await daemon.releaseAll()
        }
    }

    /// A direct turn that finds its session's record gone once it has the session's slot fails,
    /// and lets the agent held for it go, as acpx's direct turn closes the client it was handed
    /// however it ends — a caller of the direct tool has nothing else to let it go (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnWhoseRecordGoesAsItBeginsLetsItsAgentGo() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
            #expect(await !daemon.live.isEmpty)
            // The record goes as the turn takes the slot.
            await daemon.turnQueue.setBeforeAcquire { _ in
                try? FileManager.default.removeItem(at: ACPXPaths.sessionRecordPath(id))
            }
            await #expect(throws: DaemonError.self) {
                _ = try await daemon.runPrompt(sessionId: id, text: "hi", permissionMode: "approve-all", direct: true)
            }
            #expect(await daemon.live.isEmpty)
            await daemon.releaseAll()
        }
    }

    /// A direct turn that finds its session's journal corrupt fails before its attempt, and lets
    /// the agent held for it go, as acpx's direct turn closes the client it was handed however it
    /// ends (#219 review) — where a queued turn's owner keeps its agent.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnThatFindsItsJournalCorruptLetsItsAgentGo() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
            // An anchored segment, then a line that is no journal's.
            let anchor = SessionJournal.anchor(recordId: id, sequence: 1, messageSequence: 0, requestId: nil)
            try Data((anchor.stringified + "\nnot json\n").utf8).write(to: ACPXPaths.sessionStreamPath(id))
            await #expect(throws: SessionJournalError.self) {
                _ = try await daemon.runPrompt(sessionId: id, text: "hi", permissionMode: "approve-all", direct: true)
            }
            #expect(await !daemon.sessionStatus(sessionId: id).live)
            await daemon.releaseAll()
        }
    }

    /// A flow's persistent session's agents start over the flow's own environment — the one
    /// that makes the session, and the one a later turn takes it back with — as acpx starts a
    /// flow's agents in the flow's process, not over acpxd's (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aFlowsAgentsStartOverItsEnvironment() async throws {
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        let environment = { (value: String) in ProcessInfo.processInfo.environment.merging(["FLOWVAR": value]) { $1 } }
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, agentArgv: nil, cwd: NSTemporaryDirectory(), name: nil, mcpServers: nil,
                sessionOptions: nil, creation: SessionCreationMode(holdAgent: true, environment: environment("made")))
            let first = try await daemon.runPrompt(
                sessionId: id, text: "env FLOWVAR", permissionMode: "approve-all", direct: true)
            #expect(first.contains("FLOWVAR=made"), "\(first)")
            let later = try await daemon.runPrompt(
                sessionId: id, text: "env FLOWVAR", permissionMode: "approve-all", direct: true,
                environment: environment("later"))
            #expect(later.contains("FLOWVAR=later"), "\(later)")
            await daemon.releaseAll()
        }
    }

    /// The credentials in a flow's own environment sign its persistent session's agent in, as
    /// acpx finds them in the flow's process: under `fail`, a sign-in found only there is found
    /// (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aFlowsEnvironmentCredentialsSignItsAgentIn() async throws {
        let command = "/usr/bin/env MOCK_AUTH_METHODS=token " + (try #require(mockCommand()))
        let environment = ProcessInfo.processInfo.environment.merging(["ACPX_AUTH_TOKEN": "secret"]) { $1 }
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.newSession(
                agentCommand: command, agentArgv: nil, cwd: NSTemporaryDirectory(), name: nil, mcpServers: nil,
                sessionOptions: nil,
                creation: SessionCreationMode(holdAgent: true, authPolicy: "fail", environment: environment))
            await daemon.releaseAll()
        }
    }

    /// The agent that makes a flow's persistent session caps its terminals as the flow's CLI does
    /// — the caller's `ACPX_TERMINAL_MAX_OUTPUT_BYTES` — from its start, so a terminal it opens
    /// while the session is made has the flow's cap too (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aFlowSessionsCreatingAgentCapsItsTerminalsAsTheFlowDoes() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, agentArgv: nil, cwd: NSTemporaryDirectory(), name: nil, mcpServers: nil,
                sessionOptions: nil, creation: SessionCreationMode(holdAgent: true, terminalOutputCeiling: 4096))
            let agent = try #require(await daemon.live[id]?.agent)
            let terminals = try #require(agent.terminals as? TerminalManager)
            #expect(await terminals.outputCeiling == 4096)
            await daemon.releaseAll()
        }
    }

    /// A creation's call-off the daemon refuses — its connection dropped, say — keeps the token
    /// for another cleanup to try again; a settled one lets it go (#219 review).
    @Test func aRefusedCallOffKeepsItsToken() async {
        struct Refused: Error {}
        let creations = FlowCreations()
        creations.keep("token", for: "session")
        _ = await creations.callOff("session") { _ in .refused(Refused()) }
        let tried = Lines()
        _ = await creations.callOff("session") { token in
            tried.add(token)
            return .released(true)
        }
        #expect(tried.all == ["token"])
        #expect(creations.take("session") == nil)
    }

    /// As the run ends, the creations whose call-off the daemon refused are called off once
    /// more — they alone: one kept for its first turn is the runner's to let go — and each
    /// refused again is kept for yet another try, until one is settled. One called off by its
    /// token alone, its record never known, is too (#219 review).
    @Test func refusedCallOffsAreTriedAgain() async {
        struct Refused: Error {}
        let creations = FlowCreations()
        creations.keep("failed-token", for: "failed")
        creations.keep("kept-token", for: "kept")
        _ = await creations.callOff("failed") { _ in .refused(Refused()) }
        await creations.callOff(token: "unknown-token") { _ in .refused(Refused()) }
        let tried = Lines()
        let refusedAgain = await creations.callOffRefused { token in
            tried.add(token)
            return .refused(Refused())
        }
        #expect(refusedAgain is Refused)
        let settled = await creations.callOffRefused { token in
            tried.add(token)
            return .released(true)
        }
        #expect(settled == nil)
        _ = await creations.callOffRefused { token in
            tried.add(token)
            return .released(true)
        }
        #expect(tried.all == ["failed-token", "unknown-token", "failed-token", "unknown-token"])
        #expect(creations.take("failed") == nil)
        #expect(creations.take("kept") == "kept-token")
    }

    /// A flow stopped just as acpxd has made its session — the call answered, the record read —
    /// lets the session's agent go all the same: the runner registers the release as the
    /// creation ends, and a stopped attempt runs it at once, as acpx's `registerCancellation`
    /// does, with the creation's token kept by then (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionMadeAsItsFlowStopsIsLetGo() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let config = try ConfigLoader.load(cwd: NSTemporaryDirectory())
            let sessions = FlowAgentSessions(
                flags: try Flags.resolveGlobalFlags(ScannedArgs(), config: config), config: config,
                permission: .approveAll, permissionRules: nil, mcpServers: [])
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            // The node's time is up as soon as its session is made.
            let deadlines = FlowDeadlines()
            let timeUp: @Sendable (String) -> Void = { _ in deadlines.fire() }
            let run = try await DaemonClient.$standIn.withValue(daemon) {
                try await FlowAttempt.$deadlines.withValue(deadlines) {
                    try await FlowAgentSessions.$afterCreating.withValue(timeUp) {
                        try await FlowRunnerHarness.run("""
                            export default defineFlow({ name: "keep", startAt: "a", nodes: {
                              a: acp({ timeoutMs: 60000, prompt: () => "one" }) }, edges: [] });
                            """, sessions: sessions, agentCommand: command)
                    }
                }
            }
            #expect(run.err == "Timed out after 60000ms")
            #expect(await backend.live.isEmpty)
            await backend.releaseAll()
        }
    }

    /// A stopped turn still going past its grace has its agent put down when the cancel found it
    /// running or went unanswered — the release is the turn's own — and not when the cancel found
    /// it not yet begun, as it then ends as it begins (#219 review).
    @Test func aStoppedTurnsReleaseFollowsWhatItsCancelSaid() {
        #expect(FlowDaemonTurnStop.forcesRelease(cancelled: true))
        #expect(FlowDaemonTurnStop.forcesRelease(cancelled: nil))
        #expect(!FlowDaemonTurnStop.forcesRelease(cancelled: false))
    }

    /// Wait until something writes to the FIFO at `path` — read on a thread of its own, not one
    /// of Swift's, as opening it waits for its writer.
    private static func waitForWrite(to path: URL) async {
        await withCheckedContinuation { continuation in
            Thread {
                let fd = open(path.path, O_RDONLY)
                var byte: UInt8 = 0
                if fd >= 0 {
                    _ = read(fd, &byte, 1)
                    close(fd)
                }
                continuation.resume()
            }.start()
        }
    }
}
