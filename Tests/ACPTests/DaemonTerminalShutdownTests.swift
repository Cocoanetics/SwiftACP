@testable import ACPXCore
@testable import acpxd
import Foundation
@testable import SwiftACP
import Testing

/// The commands an agent runs through the daemon end once the daemon lets the agent go, as
/// acpx's client ends its terminals whenever it closes (`retireNativeResources`): on
/// `sessions close`, and when its queue owner stops. Each command leads a process group of
/// its own, so nothing else ends it: it would outlive the daemon.
extension DaemonToolsTests {
    /// How the daemon lets the session's agent go.
    enum LettingGo: String, CaseIterable, Sendable {
        /// `sessions close`.
        case closingTheSession
        /// acpxd stopping (``ACPXDaemonBackend/releaseAll()``).
        case stopping
    }

    /// A command the agent still runs once its turn is over has exited by the time the
    /// daemon has let the agent go: it is not left to look for its file.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: LettingGo.allCases)
    func lettingTheAgentGoEndsItsCommands(_ way: LettingGo) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = try Self.holdingMock(
            directory.appendingPathComponent("r"), log: directory.appendingPathComponent("requests.log"))
        try await withIsolatedStore {
            try await Self.withDaemon { daemon in
                let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
                // The agent starts the command before it answers, and waits for its exit. The
                // turn ends once its updates go quiet, and the command runs on: nothing
                // releases it.
                try await prompt(daemon, id, text: "hi", client: CallingClient())
                let (connection, _) = try #require(await daemon.agentConnection(for: id))
                let terminals = try #require(await connection.terminalHandler as? TerminalManager)
                let pid = try #require(await terminals.runningProcessIds.first)
                let running = try #require(ProcessTable.snapshot()?[pid])

                switch way {
                case .closingTheSession: #expect(try await daemon.closeSession(sessionId: id))
                case .stopping: await daemon.releaseAll()
                }

                // Gone, not only signalled: letting the agent go waits for its commands' exits.
                let after = try #require(ProcessTable.snapshot())
                #expect(after[pid]?.birth != running.birth)
            }
        }
    }
}
