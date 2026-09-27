@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// How a flow's persistent turn fails, and what it takes, in acpxd (#202, step 3b): as
/// acpx's `sendSessionDirect` fails — with the agent's error as it is, and with a permission
/// question nobody could be asked — and with the flow runner's options: its model kept with
/// the session made, and `--no-fs` given to every agent of the session.
extension DaemonToolsTests {
    /// A direct turn as a calling client's request, whose logs `client` sees; the agent's
    /// reply.
    private func directTurn(
        _ daemon: ACPXDaemonBackend, _ sessionId: String, _ text: String, permissionMode: String = "approve-all",
        fs: Bool? = nil, client: CallingClient = CallingClient()
    ) async throws -> String {
        let session = Session(id: UUID())
        await session.setTransport(client)
        return try await session.work { _ in
            try await daemon.runPrompt(
                sessionId: sessionId, text: text, permissionMode: permissionMode, nonInteractivePermissions: "fail",
                direct: true, fs: fs)
        }
    }

    /// The agent's error fails a direct turn as it is, as acpx's direct turn throws it: with
    /// no queue owner's detail code or origin, which the flow's CLI fills in as acpx's does,
    /// and with the ACP error, whose details the flow's error line carries.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnFailsWithTheAgentsErrorAsItIs() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
            let client = CallingClient()
            await #expect(throws: (any Error).self) {
                _ = try await directTurn(daemon, id, "fail turn", client: client)
            }
            let failure = try #require(client.failure)
            #expect(failure.outputCode == "RUNTIME")
            #expect(failure.detailCode == nil)
            #expect(failure.origin == nil)
            #expect(failure.acp.flatMap(AcpErrorPayload.init)?.details == "model overloaded")
        }
    }

    /// A direct turn that needed a permission question nobody could be asked fails with
    /// that, as acpx's client fails its prompt — though the agent ended the turn itself.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnFailsOnAPermissionNobodyCouldBeAsked() async throws {
        let command = try #require(mockCommand())
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: directory.path, holdAgent: true)
            let target = directory.appendingPathComponent("out.txt").path
            let client = CallingClient()
            await #expect(throws: PermissionPromptUnavailableError.self) {
                _ = try await directTurn(
                    daemon, id, "fs-write \(target) nobody may", permissionMode: "approve-reads", client: client)
            }
            #expect(client.failure?.outputCode == "PERMISSION_PROMPT_UNAVAILABLE")
            #expect(!FileManager.default.fileExists(atPath: target))
        }
    }

    /// The options' model is kept with a session made for a flow's first turn, with the
    /// rest of them, as acpx's `createSessionWithClient` records its options. The session's
    /// current model stays the agent's, as acpx 0.19.3's `sessions new --model` leaves it on
    /// this agent, whose `model` option offers the one asked for.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aHeldSessionKeepsItsModelInItsOptions() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-agent.py")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: "'\(python)' '\(fixture.path)'", cwd: NSTemporaryDirectory(),
                sessionOptions: PromptSessionOptions(model: "b", maxTurns: 2), holdAgent: true)
            let acpx = try #require(SessionStore.loadRecord(id)?.acpx)
            #expect(acpx.sessionOptions?.model == "b")
            #expect(acpx.sessionOptions?.maxTurns == 2)
            #expect(acpx.currentModelId == "a")
            await daemon.releaseAll()
        }
    }

    /// `--no-fs` reaches every agent of a flow's session — the one that made it, for the
    /// first turn, and the one a later turn takes it back with — as acpx's flow runner
    /// gives `fs` to every client it makes. The record keeps none of it: a turn without it
    /// is offered the filesystem again.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func noFsReachesEveryAgentOfAFlowsSession() async throws {
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("read-me.txt")
        try "the text".write(to: file, atomically: true, encoding: .utf8)
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, cwd: directory.path, holdAgent: true, fs: false)
            #expect(SessionStore.loadRecord(id)?.acpx?.clientCapabilities == nil)
            let refused = #"error: "Method not found": fs/read_text_file"#
            #expect(try await directTurn(daemon, id, "fs-read \(file.path)", fs: false) == refused)
            #expect(try await directTurn(daemon, id, "fs-read \(file.path)", fs: false) == refused)
            #expect(try await directTurn(daemon, id, "fs-read \(file.path)") == "the text")
        }
    }
}
