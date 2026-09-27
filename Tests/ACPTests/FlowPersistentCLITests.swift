@testable import ACPXCore
@testable import ACPXFlows
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
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
