#if os(macOS) || os(Linux)
import Foundation
@testable import SwiftACP
import Testing

/// What the client notes of an agent it starts (#221): acpx's `AcpClient.log`, which acpx
/// writes to stderr as `[acpx] <line>` under `--verbose`. Each line is acpx 0.19.3's for the
/// same launch.
@Suite struct AgentLogTests {
    /// The command it spawns, as acpx's `logAgentLaunch` writes it — the command, then its
    /// arguments joined by spaces — and once `initialize` is over, its protocol version.
    @Test(.enabled(if: mockPythonAvailable))
    func aLaunchNotesItsCommandThenItsProtocolVersion() async throws {
        let lines = Lines()
        let agent = try await Self.launch("EXIT_AGENT_CODE=3", lines)
        await agent.close()
        let python = try #require(AgentRegistry.which("python3"))
        #expect(lines.all == [
            "spawning agent: /usr/bin/env EXIT_AGENT_CODE=3 \(python) \(Self.fixture.path)",
            "initialized protocol version 1"
        ])
    }

    /// How it signs in, before the protocol version: with a credential from the client's own
    /// environment or its config, which is named — a configured one the agent's environment
    /// carries too is the config's — or without one, going on as the agent may sign in itself.
    @Test(.enabled(if: mockPythonAvailable), arguments: [
        (["ACPX_AUTH_PROBE_LOGIN": "token"], [:], "authenticated with method probe-login (env)"),
        ([:], ["probe-login": "token"], "authenticated with method probe-login (config)"),
        (["ACPX_AUTH_PROBE_LOGIN": "token"], ["probe-login": "other"], "authenticated with method probe-login (env)"),
        ([:], [:], "agent advertised auth methods [probe-login] but no matching credentials found"
            + " — skipping (agent may handle auth internally)")
    ])
    func aSignInIsNotedBeforeTheProtocolVersion(
        _ environment: [String: String], _ credentials: [String: String], _ line: String
    ) async throws {
        let lines = Lines()
        // The client's own environment, and the agent's over it, as a host starts an agent for
        // another process — acpxd, for a CLI — does: the configured credentials added.
        var caller = ProcessInfo.processInfo.environment
        caller.merge(environment) { $1 }
        let agent = try await ACPAgent.launch(
            agent: AgentEndTests.command("EXIT_AGENT_AUTH=1"), cwd: NSTemporaryDirectory(), permission: .approveAll,
            environment: AgentEnvironment.forAgent(authCredentials: credentials, sessionEnv: nil, over: caller),
            authCredentials: credentials, inheritStderr: false, terminalEnvironment: caller,
            onLog: { lines.append($0) })
        await agent.close()
        #expect(Array(lines.all.dropFirst()) == [line, "initialized protocol version 1"])
    }

    /// An agent that outlasts `SIGTERM` is noted as it is killed, as acpx's
    /// `cleanupAgentProcess` logs it.
    @Test(.enabled(if: mockPythonAvailable))
    func anAgentThatOutlastsSIGTERMIsNotedAsItIsKilled() async throws {
        let lines = Lines()
        let agent = try await Self.launch("EXIT_AGENT_STUBBORN=1", lines)
        await agent.close()
        #expect(lines.all.last == "agent processes did not exit after SIGTERM; forcing SIGKILL")
    }

    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/exit-agent.py")

    static func launch(_ environment: String, _ lines: Lines) async throws -> ACPAgent {
        try await ACPAgent.launch(
            agent: AgentEndTests.command(environment), cwd: NSTemporaryDirectory(), permission: .approveAll,
            inheritStderr: false, onLog: { lines.append($0) })
    }
}
#endif
