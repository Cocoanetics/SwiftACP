@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// Under `--verbose`, a prompt or a control run without an owner whose session could not be taken
/// back — a new session replaced it — ends with acpx's line saying why (#252):
/// `[acpx] session reconnect failed, started fresh session: <loadError>`.
@Suite(.serialized, .agentLane) struct ReconnectFallbackLineTests {
    private static let line = "[acpx] session reconnect failed, started fresh session: Resource not found: session "

    /// The turn that had to connect the agent, and replaced the session the agent could not take
    /// back, says why as it ends (``TurnEndedEvent/loadError``); a turn on the agent it left held
    /// says nothing, as acpx's owner reports `loadError` only from the connect of the turn.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theTurnThatStartedOverSaysWhy() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            // Made by one launch of the mock, the session is gone for the next.
            let created = try await SessionEngine.createSession(
                agentCommand: command, cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll,
                authCredentials: [:], authPolicy: "skip")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            var ends: [TurnEndedEvent] = []
            for text in ["hi", "again"] {
                let client = DaemonToolsTests.CallingClient()
                let session = Session(id: UUID())
                await session.setTransport(client)
                _ = try await session.work { _ in
                    try await daemon.runPrompt(sessionId: created.acpxRecordId, text: text)
                }
                ends += client.logs.compactMap { try? $0.decoded(TurnEndedEvent.self) }
            }
            await daemon.releaseAll()
            #expect(ends.map(\.loadError) == ["Resource not found: session \(created.acpSessionId)", nil])
        }
    }

    /// The CLI prints the line a turn's end brings, under `--verbose` only.
    @Test func theCLIPrintsTheLineUnderVerbose() async {
        let box = StopReasonBox()
        await box.set(TurnEndedEvent(stopReason: "end_turn", loadError: "Resource not found: session s"))
        let loadError = await box.loadError
        for verbose in [true, false] {
            let capture = Console.Capture()
            Console.$capture.withValue(capture) { DaemonClient.noteFallback(loadError, verbose: verbose) }
            #expect(capture.err == (verbose ? Self.line + "s\n" : ""))
        }
    }

    /// `acpx --approve-all --agent <agent> --cwd <cwd> <args>` against `backend`, the daemon running.
    static func acpx(_ args: [String], agent: String, cwd: URL, backend: ACPXDaemonBackend) async -> (Int32, String) {
        let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
        let capture = Console.Capture()
        let code: Int32 = await onThreadOfItsOwn {
            DaemonClient.$standIn.withValue(daemon) {
                Console.$capture.withValue(capture) {
                    runCommandLine(["--approve-all", "--agent", agent, "--cwd", cwd.path] + args)
                }
            }
        }
        return (code, capture.err)
    }

    /// A control run without an owner, which connected the agent and replaced the session it could
    /// not take back, ends with the line under `--verbose` — and without it, not at all.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlThatStartedOverSaysWhyUnderVerbose() async throws {
        let agent = try #require(mockCommand())
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(await Self.acpx(["sessions", "new"], agent: agent, cwd: directory, backend: backend).0 == 0)
            let (plainCode, plain) = await Self.acpx(
                ["set-mode", "plan"], agent: agent, cwd: directory, backend: backend)
            #expect(plainCode == 0)
            #expect(!plain.contains("session reconnect failed"))
            let (code, err) = await Self.acpx(
                ["--verbose", "set-mode", "plan"], agent: agent, cwd: directory, backend: backend)
            #expect(code == 0)
            #expect(err.split(separator: "\n").last?.hasPrefix(Self.line) == true, "\(err)")
            await backend.releaseAll()
        }
    }
}
