#if os(macOS) || os(Linux)
import Foundation
@testable import SwiftACP
import Testing

/// Grok Build signs in as acpx's client has it sign in (#231): with `xai.api_key` when the
/// client's own environment has `XAI_API_KEY`, else with `cached_token`, which the agent signs in
/// with itself — only for `grok agent stdio`. The lines are acpx 0.19.3's for the same stand-in.
@Suite struct GrokBuildAuthTests {
    /// acpx's `isGrokBuildAcpCommand`.
    @Test func grokBuildIsKnownByItsCommand() {
        #expect(GrokBuild.isAcpCommand("grok", ["agent", "stdio"]))
        #expect(GrokBuild.isAcpCommand("/usr/local/bin/GROK.exe", ["agent", "stdio", "--quiet"]))
        #expect(GrokBuild.isAcpCommand(#"C:\tools\grok.cmd"#, ["agent", "stdio"]))
        #expect(!GrokBuild.isAcpCommand("grok", ["agent"]))
        #expect(!GrokBuild.isAcpCommand("grok", ["stdio", "agent"]))
        #expect(!GrokBuild.isAcpCommand("grokker", ["agent", "stdio"]))
    }

    /// Under the `fail` policy, which either sign-in lets through.
    @Test(.enabled(if: mockPythonAvailable), arguments: [
        ([String: String](), "authenticated with method cached_token (agent)"),
        (["XAI_API_KEY": "a key"], "authenticated with method xai.api_key (env)")
    ])
    func grokBuildSignsInAsAcpxHasIt(_ environment: [String: String], _ line: String) async throws {
        let lines = Lines()
        let agent = try await Self.launch(standIn: "grok", environment: environment, lines)
        await agent.close()
        #expect(lines.all.dropFirst().first == line)
    }

    /// A key the agent is not given is not signed in with: an explicit environment without it
    /// leaves the agent its cached token (#234 review).
    @Test(.enabled(if: mockPythonAvailable))
    func aKeyTheAgentIsNotGivenLeavesItsCachedToken() async throws {
        let lines = Lines()
        let agentEnvironment = ProcessInfo.processInfo.environment.filter { key, _ in
            key != "XAI_API_KEY" && !key.hasPrefix("ACPX_AUTH_")
        }
        let agent = try await Self.launch(
            standIn: "grok", environment: ["XAI_API_KEY": "a key"], agentEnvironment: agentEnvironment, lines)
        await agent.close()
        #expect(lines.all.dropFirst().first == "authenticated with method cached_token (agent)")
    }

    /// Another agent advertising the same methods gets neither.
    @Test(.enabled(if: mockPythonAvailable))
    func anotherAgentWithTheSameMethodsGetsNeither() async throws {
        await #expect(throws: AuthPolicyError.self) {
            _ = try await Self.launch(standIn: "other", environment: ["XAI_API_KEY": "a key"], Lines())
        }
    }

    /// `<name> agent stdio`, a stand-in that runs `exit-agent.py` advertising Grok Build's methods,
    /// for a client over this process's environment and `environment` — the agent's own that too,
    /// unless `agentEnvironment` is given — under the `fail` policy.
    static func launch(
        standIn name: String, environment: [String: String], agentEnvironment: [String: String]? = nil,
        _ lines: Lines
    ) async throws -> ACPAgent {
        let python = try #require(AgentRegistry.which("python3"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent(name)
        try """
            #!/bin/sh
            exec /usr/bin/env EXIT_AGENT_AUTH=1 EXIT_AGENT_AUTH_METHODS=xai.api_key,cached_token \
              '\(python)' '\(AgentLogTests.fixture.path)'

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // Only what the case gives: a key this process has would sign the agent in otherwise.
        var caller = ProcessInfo.processInfo.environment.filter { key, _ in
            key != "XAI_API_KEY" && !key.hasPrefix("ACPX_AUTH_")
        }
        caller.merge(environment) { $1 }
        return try await ACPAgent.launch(
            agent: "'\(script.path)' agent stdio", cwd: NSTemporaryDirectory(), permission: .approveAll,
            environment: agentEnvironment ?? caller, authPolicy: "fail", inheritStderr: false,
            terminalEnvironment: caller,
            onLog: { lines.append($0) })
    }
}
#endif
