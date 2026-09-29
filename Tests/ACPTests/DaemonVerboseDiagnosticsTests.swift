@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// Under `--verbose`, what acpx writes to a flow's stderr as it runs a persistent session reaches
/// the caller of the session's creation and of each turn (#219 review, #221): the agent's own
/// stderr, and acpx's `[acpx]` lines — its client's log, whether the agent the record saved still
/// runs, each preference put back, how the agent went, and the prompt's timings — as acpx 0.19.3
/// writes them for the same mock. So does a control's caller, where no owner holds the session.
extension DaemonToolsTests {
    /// As the session is made, and as each turn runs — the one that takes the session back too. A
    /// turn without `--verbose` gets none of it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aVerboseFlowSessionsStderrReachesTheCaller() async throws {
        let command = "/usr/bin/env MOCK_STDERR_AT_START=starting MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        let spawning = "[acpx] spawning agent: " + (try AgentRegistry.commandLineParts(command).joined(separator: " "))
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let creation = CallingClient()
            let id = try await Self.makeVerboseSession(daemon, command, client: creation)
            #expect(Self.stderr(of: creation) == "starting\n")
            #expect(Self.diagnostics(of: creation) == [spawning, "[acpx] initialized protocol version 1"])
            let (first, second, quiet) = (CallingClient(), CallingClient(), CallingClient())
            _ = try await Self.verboseDirectTurn(daemon, id, "stderr one", client: first)
            _ = try await Self.verboseDirectTurn(daemon, id, "stderr two", client: second)
            _ = try await Self.verboseDirectTurn(daemon, id, "stderr three", client: quiet, verbose: false)
            // The first turn takes the agent that made the session, which runs still.
            #expect(Self.stderr(of: first) == "one\n")
            #expect(Self.diagnostics(of: first) == [
                "[acpx] saved session pid <PID> is running; reconnecting to saved ACP session",
                "[acpx] prompt.connect_and_load=<MS>ms", "[acpx] prompt.agent_turn=<MS>ms", "[acpx] prompt.total=<MS>ms"
            ])
            // The second starts one: the first's is gone, and its record keeps no pid.
            #expect(Self.stderr(of: second) == "starting\ntwo\n")
            #expect(Self.diagnostics(of: second) == [
                spawning, "[acpx] initialized protocol version 1", "[acpx] prompt.connect_and_load=<MS>ms",
                "[acpx] prompt.agent_turn=<MS>ms", "[acpx] prompt.total=<MS>ms"
            ])
            #expect(Self.stderr(of: quiet).isEmpty && Self.diagnostics(of: quiet).isEmpty)
            await daemon.releaseAll()
        }
    }

    /// An agent that goes while its prompt is out is noted before the turn's total, as acpx's
    /// `emitPromptDisconnectNotice` notes it — and no `agent_turn`: the attempt was never answered.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aVerboseTurnNotesAnAgentThatWentMidPrompt() async throws {
        let command = "/usr/bin/env MOCK_EXIT_ON_PROMPT=1 MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await Self.makeVerboseSession(daemon, command, client: CallingClient())
            let client = CallingClient()
            await #expect(throws: (any Error).self) {
                _ = try await Self.verboseDirectTurn(daemon, id, "hi", client: client)
            }
            let lines = Self.diagnostics(of: client)
            #expect(lines.count == 4, "\(lines)")
            #expect(lines.dropFirst(2).first?.hasPrefix("[acpx] agent disconnected during prompt (") == true)
            #expect(lines.last == "[acpx] prompt.total=<MS>ms")
            await daemon.releaseAll()
        }
    }

    /// A turn that takes the session back puts back the model the session wants, and notes it as
    /// acpx does, naming the session the record was on.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aVerboseTurnNotesTheModelItPutsBack() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py")
        let command = "/usr/bin/env MODEL_AGENT_LOAD=1 '\(python)' '\(fixture.path)'"
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await Self.makeVerboseSession(
                daemon, command, client: CallingClient(), options: PromptSessionOptions(model: "m2"))
            _ = try await Self.verboseDirectTurn(daemon, id, "hi", client: CallingClient())
            let second = CallingClient()
            _ = try await Self.verboseDirectTurn(daemon, id, "hi", client: second)
            let session = try #require(SessionStore.loadRecord(id)?.acpSessionId)
            #expect(Self.diagnostics(of: second).contains(
                "[acpx] replayed desired model m2 on ACP session \(session) (previous \(session))"))
            await daemon.releaseAll()
        }
    }

    /// A control under `--verbose` on a session no owner holds shows what acpx's direct control
    /// shows in the CLI's process: the agent it starts, its stderr, and acpx's lines. On a session
    /// an owner holds it shows none, as acpx's owner runs it, whose stderr is not the CLI's.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aVerboseControlShowsWhatAcpxsDirectControlShows() async throws {
        let command = "/usr/bin/env MOCK_STDERR_AT_START=starting MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        let spawning = "[acpx] spawning agent: " + (try AgentRegistry.commandLineParts(command).joined(separator: " "))
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            // Made and its agent closed, as `sessions new` leaves it: its record keeps no pid.
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let direct = CallingClient()
            _ = try await Self.verboseControl(daemon, id, client: direct)
            #expect(Self.stderr(of: direct) == "starting\n")
            #expect(Self.diagnostics(of: direct) == [spawning, "[acpx] initialized protocol version 1"])
            // A prompt leaves the session held by its owner.
            _ = try await daemon.runPrompt(sessionId: id, text: "hi", permissionMode: "approve-all")
            let owned = CallingClient()
            _ = try await Self.verboseControl(daemon, id, client: owned)
            #expect(Self.stderr(of: owned).isEmpty && Self.diagnostics(of: owned).isEmpty)
            await daemon.releaseAll()
        }
    }

    /// acpx's `formatPerfMetric`: the milliseconds to three places at most, as JavaScript writes
    /// the number.
    @Test func aTimingIsWrittenAsAcpxWritesIt() {
        #expect(PromptTimings.metric("prompt.total", milliseconds: 2409.10709) == "prompt.total=2409.107ms")
        #expect(PromptTimings.metric("prompt.total", milliseconds: 5592.28) == "prompt.total=5592.28ms")
        #expect(PromptTimings.metric("prompt.agent_turn", milliseconds: 1051) == "prompt.agent_turn=1051ms")
        #expect(PromptTimings.metric("prompt.connect_and_load", milliseconds: 0) == "prompt.connect_and_load=0ms")
    }

    /// A session made for a flow under `--verbose`, its agent held for the first turn; `client`
    /// is told what making it wrote to stderr.
    private static func makeVerboseSession(
        _ daemon: ACPXDaemonBackend, _ command: String, client: CallingClient, options: PromptSessionOptions? = nil
    ) async throws -> String {
        let session = Session(id: UUID())
        await session.setTransport(client)
        return try await session.work { _ in
            try await daemon.servingCall {
                try await daemon.newSession(
                    agentCommand: command, agentArgv: nil, cwd: NSTemporaryDirectory(), name: nil, mcpServers: nil,
                    sessionOptions: options, creation: SessionCreationMode(holdAgent: true, verbose: true))
            }
        }
    }

    /// `set-mode plan` under `--verbose`, told to `client`.
    private static func verboseControl(
        _ daemon: ACPXDaemonBackend, _ sessionId: String, client: CallingClient
    ) async throws -> SessionControlResult {
        let session = Session(id: UUID())
        await session.setTransport(client)
        return try await session.work { _ in
            try await daemon.servingCall {
                try await daemon.setMode(sessionId: sessionId, modeId: "plan", verbose: true)
            }
        }
    }

    /// A flow's direct turn, under `--verbose` unless `verbose` is false; `client` is told of it.
    private static func verboseDirectTurn(
        _ daemon: ACPXDaemonBackend, _ sessionId: String, _ text: String, client: CallingClient, verbose: Bool = true
    ) async throws -> String {
        let session = Session(id: UUID())
        await session.setTransport(client)
        return try await session.work { _ in
            try await daemon.servingCall {
                try await daemon.runPrompt(
                    sessionId: sessionId, text: text, permissionMode: "approve-all", direct: true, verbose: verbose)
            }
        }
    }
}
