@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// `sessions ensure --model` puts the model on the session it keeps, as acpx's
/// `ensureSessionWithOwnership` does (`setSessionModel`), and fails when the session cannot
/// take it. Each output is what acpx printed for the same steps on `model-agent.py`.
@Suite(.serialized) struct EnsureModelTests {
    struct Run {
        var code: Int32
        var out: String
        var err: String
    }

    /// `acpx --approve-all --agent <agent> --cwd <cwd> <args>`, with `daemon` the one running.
    private static func acpx(_ args: [String], agent: String, cwd: URL, daemon: MCPServerConfig? = nil) async -> Run {
        let capture = Console.Capture()
        let code: Int32 = await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: DaemonClient.$standIn.withValue(daemon) {
                    Console.$capture.withValue(capture) {
                        runCommandLine(["--approve-all", "--agent", agent, "--cwd", cwd.path] + args)
                    }
                })
            }.start()
        }
        return Run(code: code, out: capture.out, err: capture.err)
    }

    /// A scope with a session on the model fixture, and the session's id.
    private static func scope(_ directory: URL) async throws -> (agent: String, id: String) {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py")
        let agent = "/usr/bin/env MODEL_AGENT_LOAD=1 '\(python)' '\(fixture.path)'"
        let created = await acpx(["--format", "quiet", "sessions", "new"], agent: agent, cwd: directory)
        return (agent, created.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theModelIsPutOnTheSessionEnsureKeeps() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let (agent, id) = try await Self.scope(directory)
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let run = await Self.acpx(
                ["--model", "m2", "sessions", "ensure"], agent: agent, cwd: directory,
                daemon: .stdioHandles(server: ACPXDaemon(backend: backend)))
            await backend.releaseAll()
            #expect(run.code == 0)
            #expect(run.out == "\(id)\t(existing)\n")
            let acpx = try #require(SessionStore.loadRecord(id)?.acpx)
            #expect(acpx.currentModelId == "m2")
            #expect(acpx.sessionOptions?.model == "m2")
        }
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aModelTheSessionCannotTakeFailsTheEnsure() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let (agent, id) = try await Self.scope(directory)
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let run = await Self.acpx(
                ["--model", "bogus", "sessions", "ensure"], agent: agent, cwd: directory,
                daemon: .stdioHandles(server: ACPXDaemon(backend: backend)))
            await backend.releaseAll()
            #expect(run.code == 1)
            #expect(run.out.isEmpty)
            #expect(run.err == """
                Cannot apply --model "bogus": the ACP agent did not advertise that model. Available models: m1, m2.

                """)
            #expect(SessionStore.loadRecord(id)?.acpx?.currentModelId == "m1")
        }
    }
}
