@testable import ACPXCore
@testable import acpxd
import Foundation
@testable import SwiftACP
import Testing

/// A daemon turn caps terminal output by the ceiling its caller sent with it (#101
/// review). acpx's queue owner reads `ACPX_TERMINAL_MAX_OUTPUT_BYTES` in the environment
/// the CLI starting it passed on; the daemon outlives any one CLI, so a cap set, changed
/// or removed for a later `prompt` has to reach it with that turn.
///
/// The fixture agent runs `printf 0123456789` in a client terminal on every prompt and
/// answers with the output it read back.
extension DaemonToolsTests {
    @Test(.enabled(if: mockPythonAvailable))
    func eachTurnCapsTerminalsByItsCallersCeiling() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/write-agent.py")
        let command = "/usr/bin/env MOCK_TERMINAL='[\"printf\",\"0123456789\"]' '\(python)' '\(fixture.path)'"
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            #expect(try await daemon.runPrompt(sessionId: id, text: "go", terminalOutputCeiling: 4) == "ran:0:6789")
            #expect(try await daemon.runPrompt(sessionId: id, text: "go", terminalOutputCeiling: 0)
                == "ran:0:0123456789")
            #expect(try await daemon.runPrompt(sessionId: id, text: "go", terminalOutputCeiling: 2) == "ran:0:89")
        }
    }

    /// `write-agent.py` running `printf 0123456789` in a client terminal on every prompt,
    /// and while it answers `session/set_mode`, logging what that read back to `log`.
    private func terminalAgent(log: String) throws -> String {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/write-agent.py")
        return "/usr/bin/env MOCK_TERMINAL='[\"printf\",\"0123456789\"]' MOCK_TERMINAL_LOG='\(log)' "
            + "'\(python)' '\(fixture.path)'"
    }

    /// So does a control's caller: the cap applies to the agent before the control goes
    /// out, as to one reconnected for it.
    @Test(.enabled(if: mockPythonAvailable))
    func aControlCapsTheAgentsTerminalsByItsCallersCeiling() async throws {
        let log = NSTemporaryDirectory() + "terminal-log-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: log) }
        let command = try terminalAgent(log: log)
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.setMode(sessionId: id, modeId: "plan", terminalOutputCeiling: 4)
            let manager = try #require(await daemon.live[id]?.agent.terminals as? TerminalManager)
            #expect(await manager.outputCeiling == 4)
            _ = try await daemon.setMode(sessionId: id, modeId: "plan", terminalOutputCeiling: 0)
            #expect(await manager.outputCeiling == nil)
        }
    }

    /// What a reconnect asks of a new agent — here the saved mode, which starts a command
    /// — runs under the turn's permissions and ceiling, not the daemon's (#101 review).
    /// A control approves reads only, as acpx's direct controls do, and nobody can be
    /// asked about the rest, so the control's own command is refused.
    @Test(.enabled(if: mockPythonAvailable))
    func aReplayRunsUnderTheTurnsPermissionsAndCeiling() async throws {
        let log = NSTemporaryDirectory() + "terminal-log-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: log) }
        let command = try terminalAgent(log: log)
        let refused = "error:Permission denied for terminal/create"
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.setMode(sessionId: id, modeId: "plan")
            await daemon.evict(id)
            #expect(try await daemon.runPrompt(
                sessionId: id, text: "go", permissionMode: "approve-all", terminalOutputCeiling: 2) == "ran:0:89")
            await daemon.evict(id)
            #expect(try await daemon.runPrompt(sessionId: id, text: "go", permissionMode: "deny-all") == refused)
            #expect(try String(contentsOfFile: log, encoding: .utf8) == "\(refused)\nran:0:89\n\(refused)\n")
        }
    }

    /// A command the agent starts while it answers `initialize` is capped by the caller's
    /// ceiling already: the launch builds the agent's terminal manager with it (#101
    /// review). The fixture logs what that command printed; the daemon's own launch, for
    /// `newSession`, has no cap.
    @Test(.enabled(if: mockPythonAvailable))
    func aCommandStartedDuringInitializeIsCappedByTheCallersCeiling() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/write-agent.py")
        let log = NSTemporaryDirectory() + "initialize-log-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: log) }
        let command = "/usr/bin/env MOCK_TERMINAL='[\"printf\",\"0123456789\"]' MOCK_TERMINAL_ON_INITIALIZE=ok "
            + "MOCK_TERMINAL_LOG='\(log)' '\(python)' '\(fixture.path)'"
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            await daemon.evict(id)
            _ = try await daemon.runPrompt(
                sessionId: id, text: "go", permissionMode: "approve-all", terminalOutputCeiling: 4)
            #expect(try String(contentsOfFile: log, encoding: .utf8) == "0123456789" + "6789")
        }
    }

    /// A caller's ceiling is held to the environment variable's rule, before the turn
    /// is queued.
    @Test func aNegativeCeilingIsRefused() async throws {
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await #expect(throws: TerminalOutputCeilingError()) {
                try await daemon.runPrompt(sessionId: "any", text: "go", terminalOutputCeiling: -1)
            }
        }
    }
}
