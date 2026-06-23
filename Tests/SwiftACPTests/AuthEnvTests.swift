import ACP
import Foundation
import Testing

/// Locks down the auth-credential env injection ported from acpx `acp/auth-env.ts`:
/// configured `auth` entries become environment variables for the spawned agent
/// (so e.g. a per-project `CODEX_HOME` selects a different codex login).
struct AuthEnvTests {
    @Test func envTokenNormalization() {
        #expect(AgentEnvironment.toEnvToken("CODEX_HOME") == "CODEX_HOME")
        #expect(AgentEnvironment.toEnvToken("OPENAI_API_KEY") == "OPENAI_API_KEY")
        #expect(AgentEnvironment.toEnvToken("openai-api.key") == "OPENAI_API_KEY")
        #expect(AgentEnvironment.toEnvToken("  --weird__id--  ") == "WEIRD_ID")
        #expect(AgentEnvironment.toEnvToken("a..b--c") == "A_B_C")
    }

    @Test func forAgentInjectsConfiguredCredentialAsEnvVar() {
        // The headline use case: a per-project CODEX_HOME → different codex login.
        let env = AgentEnvironment.forAgent(
            authCredentials: ["CODEX_HOME": "/Users/x/.codex-work"])
        #expect(env["CODEX_HOME"] == "/Users/x/.codex-work")
        // Also exposed under the prefixed + normalized names.
        #expect(env["ACPX_AUTH_CODEX_HOME"] == "/Users/x/.codex-work")
    }

    @Test func forAgentInjectsNonEnvNameOnlyUnderTokenForms() {
        let env = AgentEnvironment.forAgent(
            authCredentials: ["my-auth.method": "secret"])
        #expect(env["ACPX_AUTH_MY_AUTH_METHOD"] == "secret")
        #expect(env["MY_AUTH_METHOD"] == "secret")
    }

    @Test func forAgentDoesNotOverrideExistingProcessVar() {
        // PATH is always set; injection must not clobber it.
        let existingPath = ProcessInfo.processInfo.environment["PATH"]
        let env = AgentEnvironment.forAgent(authCredentials: ["PATH": "/injected"])
        #expect(env["PATH"] == existingPath)
    }

    @Test func forAgentStripsNothing() {
        // acpx inherits the full parent environment — nothing is removed (so an
        // inherited CLAUDE_CODE_OAUTH_TOKEN / host marker passes straight through).
        let inherited = ProcessInfo.processInfo.environment
        let env = AgentEnvironment.forAgent()
        for (key, value) in inherited {
            #expect(env[key] == value, "inherited \(key) must pass through unchanged")
        }
    }

    @Test func resolveConfiguredCredentialByIdAndToken() {
        let creds = ["OPENAI_API_KEY": "by-id", "OTHER_KEY": "by-token"]
        #expect(
            AgentEnvironment.resolveConfiguredAuthCredential(
                methodId: "OPENAI_API_KEY", authCredentials: creds) == "by-id")
        // method id "other-key" normalizes to OTHER_KEY.
        #expect(
            AgentEnvironment.resolveConfiguredAuthCredential(
                methodId: "other-key", authCredentials: creds) == "by-token")
        #expect(
            AgentEnvironment.resolveConfiguredAuthCredential(
                methodId: "absent", authCredentials: creds) == nil)
    }
}
