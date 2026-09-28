@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// acpx gives two agents that are known to stall as they start a limit (#248): Gemini's
/// `initialize` 15 s (`ACPX_GEMINI_ACP_STARTUP_TIMEOUT_MS`) and Claude's adapter's `session/new`
/// 60 s (`ACPX_CLAUDE_ACP_SESSION_CREATE_TIMEOUT_MS`), each failing as a timeout that says why.
@Suite(.serialized, .agentLane) struct StartupLimitTests {
    /// acpx's `resolveGeminiAcpStartupTimeoutMs`: `Number` of the variable, when positive and
    /// finite, rounded; `withTimeout` waits without a limit that rounds to 0, and Node's
    /// `setTimeout` takes one past its maximum as 1 ms.
    @Test func aLimitIsReadAsAcpxReadsIt() {
        let limit = { AgentLaunchCompat.startupMilliseconds($0, fallback: 15_000) }
        #expect(limit(nil) == 15_000)
        #expect(limit("1500") == 1_500)
        #expect(limit(" 2e3 ") == 2_000)
        #expect(limit("0x10") == 16)
        #expect(limit("1.5") == 2)
        #expect(limit("0.4") == nil)
        #expect(limit("3000000000") == 1)
        for fallback in ["", "  ", "-5", "0", "abc", "Infinity", "1_000"] { #expect(limit(fallback) == 15_000) }
    }

    @Test func claudesAdapterIsKnownByItsName() {
        #expect(AgentLaunchCompat.isClaude("/usr/local/bin/claude-agent-acp", []))
        #expect(AgentLaunchCompat.isClaude("npx", ["-y", "@agentclientprotocol/claude-agent-acp@^0.76.0"]))
        #expect(!AgentLaunchCompat.isClaude("claude", ["--acp"]))
    }

    /// acpx's `buildGeminiAcpStartupTimeoutMessage`: the version Gemini gives, and the keys the
    /// agent's environment lacks.
    @Test func geminisStallSaysWhatItKnows() async {
        let stalled = { (version: String?, environment: [String: String]) in
            await AgentLaunchCompat.geminiStartupTimeoutMessage(
                "gemini", agentEnvironment: environment, probe: { _, _, _ in version })
        }
        let head = "Gemini CLI ACP startup timed out before initialize completed. This usually means the local "
            + "Gemini CLI is waiting on interactive OAuth or has incompatible ACP subprocess behavior."
        let tail = "Try upgrading Gemini CLI and using API-key-based auth for non-interactive ACP runs."
        let noKey = "No GEMINI_API_KEY or GOOGLE_API_KEY was set for non-interactive auth."
        #expect(await stalled("gemini 0.40.0\n", [:])
            == "\(head) Detected Gemini CLI version: gemini 0.40.0. \(noKey) \(tail)")
        #expect(await stalled(nil, ["GOOGLE_API_KEY": "k"]) == "\(head) \(tail)")
        #expect(await stalled(nil, ["GEMINI_API_KEY": ""]) == "\(head) \(noKey) \(tail)")
    }

    /// Both fail as acpx's timeouts: `TIMEOUT`, their detail codes, worth retrying.
    @Test func theyFailAsTimeouts() {
        for (error, detail) in [
            (GeminiAcpStartupTimeoutError(message: "m") as Error, "GEMINI_ACP_STARTUP_TIMEOUT"),
            (ClaudeAcpSessionCreateTimeoutError(), "CLAUDE_ACP_SESSION_CREATE_TIMEOUT")
        ] {
            let failure = ExecCommand.RunFailure(error)
            #expect(failure.outputCode == "TIMEOUT")
            #expect(failure.detailCode == detail)
            #expect(failure.origin == "acp")
            #expect(failure.retryable == true)
        }
    }

    /// A Gemini that does not answer `initialize` within its limit is ended, and the launch fails
    /// saying what `gemini --version` says, asked again once it is gone.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aGeminiThatStallsInInitializeIsEnded() async throws {
        let directory = try AgentLaunchCompatTests.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gemini = try AgentLaunchCompatTests.fakeCLI(
            "gemini", in: directory, version: "gemini 0.40.0", environment: ["MOCK_NEVER_ANSWER": "initialize"])
        do {
            // The agent's environment has no API keys; the limit is the caller's.
            _ = try await ACPAgent.launch(
                agent: "'\(gemini)' --acp", cwd: directory.path, permission: .approveAll,
                environment: ["PATH": "/usr/bin:/bin"],
                terminalEnvironment: ["ACPX_GEMINI_ACP_STARTUP_TIMEOUT_MS": "300"])
            Issue.record("a Gemini that never answered initialize was launched")
        } catch let error as GeminiAcpStartupTimeoutError {
            #expect(error.message.contains("Detected Gemini CLI version: gemini 0.40.0."))
            #expect(error.message.contains("No GEMINI_API_KEY or GOOGLE_API_KEY was set"))
        }
    }

    /// Claude's adapter that does not answer `session/new` within its limit fails the session.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func claudesAdapterThatStallsInSessionNewFailsIt() async throws {
        let directory = try AgentLaunchCompatTests.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let claude = try AgentLaunchCompatTests.fakeCLI(
            "claude-agent-acp", in: directory, environment: ["MOCK_NEVER_ANSWER": "session/new"])
        let agent = try await ACPAgent.launch(
            agent: "'\(claude)'", cwd: directory.path, permission: .approveAll,
            terminalEnvironment: ["ACPX_CLAUDE_ACP_SESSION_CREATE_TIMEOUT_MS": "300"])
        await #expect(throws: ClaudeAcpSessionCreateTimeoutError()) {
            _ = try await agent.newSession(cwd: directory.path)
        }
        await agent.close()
    }
}
