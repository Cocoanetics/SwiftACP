@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// A control the agent turns down is reported by the daemon as acpx's CLI reports it
/// (#164): a rejection says which control and what was asked, and any other agent error
/// is its message alone (`formatErrorMessage`).
extension DaemonToolsTests {
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: [
        (#"{"code":-32602,"message":"Invalid params"}"#,
         #"Agent rejected session/set_mode for mode "plan": Invalid params (ACP -32602). The adapter may not "#
            + "implement session/set_mode, or the requested value is not supported."),
        (#"{"code":-32000,"message":"boom"}"#, "boom")
    ])
    func aModeTheAgentTurnsDownIsReportedAsAcpxReportsIt(error: String, reported: String) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: "RETRY_AGENT_SET_MODE_ERROR='\(error)' ")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            do {
                _ = try await daemon.setMode(sessionId: session.id, modeId: "plan")
                Issue.record("the mode was set")
            } catch {
                #expect(error.localizedDescription == reported)
            }
            await daemon.releaseAll()
        }
    }

    /// A control the agent refuses reaches the CLI with what the daemon said of it beyond its
    /// message (#171), and is reported as acpx 0.19.3 reports the same refusal: in JSON by the
    /// agent's own code, message and data; and when the session's owner ran it, with the owner's
    /// detail code and origin, as acpx's owner answers it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: [false, true])
    func aRefusedControlIsReportedAsAcpxReportsIt(owned: Bool) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let (agent, id) = try await refusingSession(
                in: directory, error: #"{"code":-32602,"message":"Invalid params","data":{"fixture":"mode"}}"#)
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            if owned { try await limitedPrompt(backend, id, limits: PromptLimits(ttlMs: 0), client: CallingClient()) }
            let setMode = ["set-mode", "plan"]
            let json = await Self.acpx(["--format", "json"] + setMode, agent: agent, cwd: directory, backend)
            let quiet = await Self.acpx(["--format", "quiet"] + setMode, agent: agent, cwd: directory, backend)
            await backend.releaseAll()

            let owner = owned ? #""detailCode":"QUEUE_CONTROL_REQUEST_FAILED","origin":"queue""# : #""origin":"cli""#
            #expect(json.code == 1)
            #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32602,"message":"Invalid params","#
                + #""data":{"acpxCode":"RUNTIME","# + owner + #","sessionId":"unknown","fixture":"mode"}}}"# + "\n")
            #expect(quiet.code == 1)
            #expect(quiet.err == "[acpx] error: RUNTIME " + (owned ? "QUEUE_CONTROL_REQUEST_FAILED " : "")
                + #"Agent rejected session/set_mode for mode "plan": Invalid params (ACP -32602). The adapter may "#
                + "not implement session/set_mode, or the requested value is not supported.\n")
        }
    }

    /// An agent that refuses a control for want of credentials gets acpx's hint for them when
    /// the control ran directly. acpx's owner answers under a detail code of its own, which
    /// has no hint — so there is none when the session's owner ran it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: [false, true])
    func aControlRefusedForCredentialsHintsAtThemOnlyWhenRunDirectly(owned: Bool) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let (agent, id) = try await refusingSession(
                in: directory,
                error: #"{"code":-32000,"message":"Authentication required","data":{"methodId":"login"}}"#)
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            if owned { try await limitedPrompt(backend, id, limits: PromptLimits(ttlMs: 0), client: CallingClient()) }
            let text = await Self.acpx(["--format", "text", "set-mode", "plan"], agent: agent, cwd: directory, backend)
            await backend.releaseAll()

            #expect(text.code == 1)
            #expect(text.err == "Authentication required\n" + (owned ? "" : "hint: run `acpx config show` to "
                + "locate the active config, then add `auth.login` and retry.\n"))
        }
    }

    /// What the daemon's tools say of a failure beyond its message (#171): what it says of itself
    /// for acpx's output, and the agent's error it is — nothing for one that says none of that.
    @Test func aFailureIsDescribedAsAcpxsOutputReadsIt() throws {
        let backend = ACPXDaemonBackend(inheritAgentStderr: false)
        let refusal = AgentFailure.shown(JSONRPCErrorBody(code: -32602, message: "Invalid params", data: ["a": 1]))
        let described = try #require(backend.toolFailure(for: refusal))
        #expect(described.outputCode == nil && described.detailCode == nil && described.origin == nil)
        #expect(described.acp.flatMap(AcpErrorPayload.init)
            == AcpErrorPayload(code: -32602, message: "Invalid params", data: WireJSON(["a": 1])))

        let timedOut = try #require(backend.toolFailure(for: OwnedControlFailure(TimeoutError(milliseconds: 300))))
        #expect(timedOut
            == ToolFailure(outputCode: "TIMEOUT", detailCode: "QUEUE_CONTROL_REQUEST_FAILED", origin: "queue"))
        // The session gone, by the code of the agent's error its owner's answer is.
        let gone = AgentFailure.shown(JSONRPCErrorBody(code: -32002, message: "Gone"))
        #expect(backend.toolFailure(for: OwnedControlFailure(gone))?.outputCode == "NO_SESSION")

        #expect(backend.toolFailure(for: DaemonError.sessionNotFound("x")) == nil)
        #expect(backend.toolFailure(for: CancellationError()) == nil)
    }

    /// A session at `directory` whose agent, the retry agent, answers `session/set_mode` with
    /// `error`, and the command that runs the agent.
    private func refusingSession(in directory: URL, error: String) async throws -> (agent: String, id: String) {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/retry-agent.py")
        let agent = "/usr/bin/env RETRY_AGENT_SET_MODE_ERROR='\(error)' '\(python)' '\(fixture.path)'"
        let created = try await SessionEngine.createSession(
            agentCommand: agent, cwd: directory.path, name: nil, permission: .approveAll, authCredentials: [:],
            authPolicy: "skip")
        return (agent, created.acpxRecordId)
    }

    /// `acpx --agent <agent> --cwd <cwd> <args>` against `backend`: its exit code and what it wrote.
    private static func acpx(
        _ args: [String], agent: String, cwd: URL, _ backend: ACPXDaemonBackend
    ) async -> CLIRun {
        let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
        let capture = Console.Capture()
        let code: Int32 = await onThreadOfItsOwn {
            DaemonClient.$standIn.withValue(daemon) {
                Console.$capture.withValue(capture) { runCommandLine(["--agent", agent, "--cwd", cwd.path] + args) }
            }
        }
        return CLIRun(code: code, out: capture.out, err: capture.err)
    }
}
