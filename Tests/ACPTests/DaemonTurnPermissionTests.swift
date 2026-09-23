@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A daemon turn applies the permission mode the caller sent *with that turn* — acpx
/// sends `permissionMode` with every prompt and its queue owner applies it per turn.
/// The daemon used to launch agents with `.approveAll` and never change it, so
/// `acpx --deny-all prompt …` approved every tool call and every file write.
///
/// The fixture agent writes `written.txt` on every prompt and answers with what the
/// client said, so the effect of each turn's mode is visible in the reply.
extension DaemonToolsTests {
    private func writeAgentCommand() throws -> String {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/write-agent.py")
        return "'\(python)' '\(fixture.path)'"
    }

    private func freshCwd() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("turn-perm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    @Test(.enabled(if: mockPythonAvailable))
    func denyAllRefusesTheTurnsWrites() async throws {
        let command = try writeAgentCommand()
        let cwd = try freshCwd()
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: cwd)
            let reply = try await daemon.runPrompt(
                sessionId: id, text: "go", permissionMode: "deny-all")
            #expect(reply == "error:Permission denied for fs/write_text_file")
            #expect(!FileManager.default.fileExists(atPath: cwd + "/written.txt"))
        }
    }

    /// The daemon has no terminal to ask on — like acpx's detached queue owner — so a
    /// write needing confirmation is refused, or refused as unanswerable under `fail`.
    @Test(.enabled(if: mockPythonAvailable))
    func approveReadsNeverPromptsOnTheDaemonsTerminal() async throws {
        let command = try writeAgentCommand()
        let cwd = try freshCwd()
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: cwd)
            let denied = try await daemon.runPrompt(
                sessionId: id, text: "go", permissionMode: "approve-reads")
            #expect(denied == "error:Permission denied for fs/write_text_file")
            let unanswerable = try await daemon.runPrompt(
                sessionId: id, text: "go", permissionMode: "approve-reads",
                nonInteractivePermissions: "fail")
            #expect(unanswerable == "error:Permission prompt unavailable in non-interactive mode")
        }
    }

    /// The mode belongs to the turn, not the session: the same live session refuses a
    /// write under one mode and allows it under the next.
    @Test(.enabled(if: mockPythonAvailable))
    func theModeAppliesToOneTurnOnly() async throws {
        let command = try writeAgentCommand()
        let cwd = try freshCwd()
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: cwd)
            #expect(try await daemon.runPrompt(sessionId: id, text: "go", permissionMode: "deny-all")
                == "error:Permission denied for fs/write_text_file")
            #expect(try await daemon.runPrompt(sessionId: id, text: "go", permissionMode: "approve-all")
                == "ok")
            #expect(FileManager.default.fileExists(atPath: cwd + "/written.txt"))
        }
    }

    /// A caller that predates the parameter keeps what it had: everything approved.
    @Test(.enabled(if: mockPythonAvailable))
    func anOmittedModeKeepsTheOldBehaviour() async throws {
        let command = try writeAgentCommand()
        let cwd = try freshCwd()
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: cwd)
            #expect(try await daemon.runPrompt(sessionId: id, text: "go") == "ok")
        }
    }

    @Test func anUnknownModeIsRefusedBeforeTheTurnIsQueued() throws {
        #expect(throws: DaemonError.self) {
            _ = try TurnPermissions(mode: "approve-some", nonInteractive: nil)
        }
        #expect(throws: DaemonError.self) {
            _ = try TurnPermissions(mode: "deny-all", nonInteractive: "maybe")
        }
        #expect(throws: Never.self) {
            _ = try TurnPermissions(mode: "approve-reads", nonInteractive: "fail")
        }
    }
}
