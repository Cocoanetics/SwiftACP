@testable import SwiftACP
import Testing

/// The environment an agent is started with — acpx's `buildAgentEnvironment` (#108):
/// the parent's, `ACPX_AUTH_*` promoted, the configured credentials, and the session's
/// own variables over them, save the credential variables acpx manages.
struct AgentEnvironmentTests {
    @Test func aSessionsVariablesGoOverTheParentsButNotTheCredentials() {
        let environment = AgentEnvironment.forAgent(
            authCredentials: ["probe-login": "secret"],
            sessionEnv: [
                "PROBE_LOGIN": "session", "ACPX_AUTH_PROBE_LOGIN": "session", "probe-login": "session",
                "ACPX_AUTH_OTHER": "session", "OTHER": "session",
                "CustomMixedCase": "1", "INHERITED": "session"
            ],
            over: ["INHERITED": "parent", "ACPX_AUTH_OTHER": "promoted"])
        // The credential's variables and a promoted one's are acpx's to set.
        #expect(environment["PROBE_LOGIN"] == "secret")
        #expect(environment["ACPX_AUTH_PROBE_LOGIN"] == "secret")
        #expect(environment["probe-login"] == "secret")
        #expect(environment["ACPX_AUTH_OTHER"] == "promoted")
        #expect(environment["OTHER"] == "promoted")
        // Anything else the session sets, it gets.
        #expect(environment["CustomMixedCase"] == "1")
        #expect(environment["INHERITED"] == "session")
    }

    /// A promoted variable's name is its suffix as an env-token, as acpx normalizes it.
    @Test func aPromotedVariableIsNamedByItsToken() {
        let environment = AgentEnvironment.forAgent(
            authCredentials: [:], sessionEnv: nil, over: ["ACPX_AUTH_open-ai key": "k"])
        #expect(environment["OPEN_AI_KEY"] == "k")
    }
}
