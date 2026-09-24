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
