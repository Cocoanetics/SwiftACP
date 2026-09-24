@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
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

    /// So does a control's caller: an agent can start a command while it answers one.
    /// The fixture runs `printf 0123456789` while it answers `session/set_mode`, and logs
    /// what it read back. A reconnect's replay of the mode runs under the turn's ceiling,
    /// which applies before anything is asked of the new agent.
    @Test(.enabled(if: mockPythonAvailable))
    func aControlAndAReplayCapTerminalsByTheirCallersCeiling() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/write-agent.py")
        let log = NSTemporaryDirectory() + "terminal-log-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: log) }
        let command = "/usr/bin/env MOCK_TERMINAL='[\"printf\",\"0123456789\"]' MOCK_TERMINAL_LOG='\(log)' "
            + "'\(python)' '\(fixture.path)'"
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.setMode(sessionId: id, modeId: "plan", terminalOutputCeiling: 4)
            _ = try await daemon.setMode(sessionId: id, modeId: "plan", terminalOutputCeiling: 0)
            await daemon.evict(id)
            #expect(try await daemon.runPrompt(sessionId: id, text: "go", terminalOutputCeiling: 2) == "ran:0:89")
            #expect(try String(contentsOfFile: log, encoding: .utf8) == "ran:0:6789\nran:0:0123456789\nran:0:89\n")
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
