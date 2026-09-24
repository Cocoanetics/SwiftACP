@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

#if canImport(Glibc)
import Glibc
#endif

/// What acpxd keeps of how its agent is doing, as acpx's queue owner keeps it (#87):
/// closing a new session's agent is put down to the connection, a turn on a live agent
/// records its pid, and an agent exiting mid-turn fails the turn in acpx's words and
/// leaves its exit in the record.
extension DaemonToolsTests {
    /// SwiftACPTests' `exit-agent.py`, run with `environment`.
    static func exitAgent(_ environment: String) throws -> String {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftACPTests/Fixtures/exit-agent.py")
        return "/usr/bin/env \(environment) '\(python)' '\(fixture.path)'"
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aTurnTheAgentExitsInRecordsHowItEnded() async throws {
        let armed = NSTemporaryDirectory() + "exit-agent-armed-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: armed) }
        let command = try Self.exitAgent("EXIT_AGENT_ARMED='\(armed)' EXIT_AGENT_CODE=3")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let created = try #require(SessionStore.loadRecord(id))
            #expect(created.pid == nil)
            #expect(created.agentStartedAt != nil)
            #expect(created.lastAgentDisconnectReason == "connection_close")
            #expect(created.lastAgentExitCode.map { $0.value == nil } == true)

            try await prompt(daemon, id, text: "first", client: CallingClient())
            let held = try #require(SessionStore.loadRecord(id))
            let pid = try #require(held.pid)
            #expect(kill(pid_t(pid), 0) == 0)
            #expect(held.lastAgentDisconnectReason == nil)
            #expect(held.lastAgentExitCode == nil)
            #expect(held.lastAgentExitAt == nil)

            try "".write(toFile: armed, atomically: true, encoding: .utf8)
            let client = CallingClient()
            await #expect(throws: AgentDisconnectedError.self) {
                try await prompt(daemon, id, text: "second", client: client)
            }
            let failure = try #require(client.failure)
            #expect(failure.outputCode == "RUNTIME")
            #expect(failure.detailCode == "AGENT_DISCONNECTED")
            #expect(failure.origin == "acp")
            #expect(failure.message == "ACP agent disconnected during request (process_exit, exit=3, signal=null)")
            let ended = try #require(SessionStore.loadRecord(id))
            #expect(ended.pid == nil)
            #expect(ended.lastAgentExitCode?.value == 3)
            #expect(ended.lastAgentExitSignal.map { $0.value == nil } == true)
            #expect(ended.lastAgentExitAt != nil)
            #expect(ended.lastAgentDisconnectReason == "process_exit")
        }
    }

    /// An agent whose stdout closed mid-turn, though it runs on, is ended before its end
    /// is recorded: the record keeps no pid for it (#113 review).
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnWhoseAgentClosedItsStdoutKeepsNoPid() async throws {
        let command = try Self.exitAgent("EXIT_AGENT_CLOSE_STDOUT=1")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            await #expect(throws: AgentDisconnectedError.self) {
                try await prompt(daemon, id, text: "hi", client: CallingClient())
            }
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.pid == nil)
            #expect(record.lastAgentDisconnectReason == "pipe_close")
        }
    }

    /// So is one whose stdout closed while it answered a control (#113 review).
    @Test(.enabled(if: mockPythonAvailable))
    func aControlWhoseAgentClosedItsStdoutKeepsNoPid() async throws {
        let command = try Self.exitAgent("EXIT_AGENT_CLOSE_STDOUT=set_mode")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            await #expect(throws: AgentDisconnectedError.self) {
                _ = try await daemon.setMode(sessionId: id, modeId: "plan")
            }
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.pid == nil)
            #expect(record.lastAgentDisconnectReason == "pipe_close")
        }
    }

    /// Closing an agent is what its end is put down to, however fast it exits once its
    /// stdin ends: the transport is closed before the stdin is (#113 review).
    @Test(.enabled(if: mockPythonAvailable))
    func closingAnAgentIsWhatItsEndIsPutDownTo() async throws {
        for _ in 0..<5 {
            let agent = try await ACPAgent.launch(
                agent: Self.exitAgent(""), cwd: NSTemporaryDirectory(), permission: .approveAll, inheritStderr: false)
            await agent.close()
            #expect(agent.lifecycle?.lastExit?.reason == .connectionClose)
        }
    }

    /// A control the agent exits in leaves its exit in the record too, and nothing of the
    /// control (#113 review).
    @Test(.enabled(if: mockPythonAvailable))
    func aControlTheAgentExitsInRecordsHowItEnded() async throws {
        let command = try Self.exitAgent("EXIT_AGENT_ON=set_mode EXIT_AGENT_CODE=4")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            await #expect(throws: AgentDisconnectedError.self) {
                _ = try await daemon.setMode(sessionId: id, modeId: "plan")
            }
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.pid == nil)
            #expect(record.lastAgentExitCode?.value == 4)
            #expect(record.lastAgentDisconnectReason == "process_exit")
            #expect(record.acpx?.desiredModeId == nil)
        }
    }

    /// A held agent whose stdin closed between turns never gets the next prompt: its
    /// write fails, so the turn goes to a fresh launch unseen. Only a prompt written to
    /// the agent counts as sent, as acpx's `onPromptRequestWritten` has it (#113 review).
    @Test(.enabled(if: mockPythonAvailable))
    func aPromptAHeldAgentCouldNotBeSentGoesToAFreshLaunch() async throws {
        let armed = NSTemporaryDirectory() + "exit-agent-stdin-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: armed) }
        let command = try Self.exitAgent("EXIT_AGENT_CLOSE_STDIN_ARMED='\(armed)'")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            try "".write(toFile: armed, atomically: true, encoding: .utf8)
            try await prompt(daemon, id, text: "first", client: CallingClient())
            let first = try #require(SessionStore.loadRecord(id)?.pid)
            try await prompt(daemon, id, text: "second", client: CallingClient())
            let second = try #require(SessionStore.loadRecord(id)?.pid)
            #expect(second != first)
        }
    }

    /// Stopping the daemon lets its agents go as acpx's queue owner does when it stops:
    /// each record keeps no pid and names the connection its agent was closed on (#113
    /// review).
    @Test(.enabled(if: mockPythonAvailable))
    func stoppingTheDaemonRecordsHowItsAgentsEnded() async throws {
        let command = try Self.exitAgent("")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            try await prompt(daemon, id, text: "hi", client: CallingClient())
            let pid = try #require(SessionStore.loadRecord(id)?.pid)
            await daemon.releaseAll()
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.pid == nil)
            #expect(kill(pid_t(pid), 0) != 0)
            #expect(record.lastAgentDisconnectReason == "connection_close")
            #expect(record.lastAgentExitCode.map { $0.value == nil } == true)
            #expect(record.lastAgentExitSignal.map { $0.value == nil } == true)
            #expect(record.lastAgentExitAt != nil)
        }
    }
}
