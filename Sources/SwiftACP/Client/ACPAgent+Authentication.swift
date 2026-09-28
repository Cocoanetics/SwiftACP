#if os(macOS) || os(Linux) || os(Windows)
import Foundation

extension ACPAgent {
    /// After `initialize`, if the agent advertised auth methods, select a
    /// credential (this process's `ACPX_AUTH_*` env first, then configured
    /// `auth`) and call ACP `authenticate`, noting to `log` the method and where its
    /// credential came from. When none match: throw under the `fail` policy, else note it
    /// and proceed (the agent may authenticate itself). Faithful to acpx's
    /// `authenticateIfRequired`/`selectAuthMethod`.
    static func authenticateIfRequired(
        connection: ACPAgentConnection,
        methods: [AuthMethod],
        authCredentials: [String: String],
        authPolicy: String,
        environment: [String: String],
        callerEnvironment: [String: String],
        log: RawWireTap,
        grokBuild: Bool = false
    ) async throws {
        guard !methods.isEmpty else { return }
        for method in methods {
            // The environment the agent runs with: the starting process's, or the caller's own.
            let hasEnv = AgentEnvironment.readEnvCredential(methodId: method.id, in: environment) != nil
            let configCredential = AgentEnvironment.resolveConfiguredAuthCredential(
                methodId: method.id, authCredentials: authCredentials)
            let hasConfig =
                configCredential?.trimmingCharacters(in: .whitespaces).isEmpty == false
            if hasEnv || hasConfig {
                try await connection.authenticate(methodId: method.id)
                let source = fromConfig(
                    method.id, configCredential: hasConfig ? configCredential : nil, environment: environment,
                    callerEnvironment: callerEnvironment) ? "config" : "env"
                log.log("authenticated with method \(method.id) (\(source))")
                return
            }
            // Grok Build's API key, which acpx takes from `XAI_API_KEY` (`readAgentSpecificEnvCredential`)
            // — so long as the agent has it too: the sign-in names only the method, and an agent
            // given an environment without the key could not sign in with it (#234 review).
            if grokBuild, GrokBuild.apiKey(for: method.id, in: callerEnvironment) != nil,
               GrokBuild.apiKey(for: method.id, in: environment) != nil {
                try await connection.authenticate(methodId: method.id)
                log.log("authenticated with method \(method.id) (env)")
                return
            }
        }
        // Grok Build's cached sign-in, which acpx selects for the agent to sign in with itself
        // (`selectAgentManagedAuthMethod`), once no method has a credential.
        if grokBuild, let managed = methods.first(where: { $0.id == GrokBuild.cachedTokenMethod }) {
            try await connection.authenticate(methodId: managed.id)
            log.log("authenticated with method \(managed.id) (agent)")
            return
        }
        let advertised = methods.map(\.id).joined(separator: ", ")
        if authPolicy == "fail" {
            throw AuthPolicyError(methodIds: methods.map(\.id))
        }
        log.log("agent advertised auth methods [\(advertised)] but no matching credentials found"
            + " — skipping (agent may handle auth internally)")
    }

    /// Whether the credential `methodId` signs in with is the configured one, as acpx's
    /// `selectAuthMethod` names it: only when the client's own environment has none — acpx looks
    /// there first — and the agent's environment holds the configured credential, which launching
    /// puts there, or none. One the agent's environment holds of its own — given it explicitly —
    /// is the environment's (#233 review).
    private static func fromConfig(
        _ methodId: String, configCredential: String?, environment: [String: String],
        callerEnvironment: [String: String]
    ) -> Bool {
        guard let configCredential,
              AgentEnvironment.readEnvCredential(methodId: methodId, in: callerEnvironment) == nil else { return false }
        let agents = AgentEnvironment.readEnvCredential(methodId: methodId, in: environment)
        return agents == nil || agents == configCredential
    }
}

/// Grok Build's own sign-in, as acpx's client has it for `grok agent stdio` (openclaw/acpx#426).
enum GrokBuild {
    /// The method whose credential is `XAI_API_KEY`.
    static let apiKeyMethod = "xai.api_key"
    /// The method the agent signs in with itself, with the token it has cached.
    static let cachedTokenMethod = "cached_token"

    /// acpx's `isGrokBuildAcpCommand`: the executable's name — its last path component, without a
    /// `.cmd`, `.exe` or `.ps1`, in lowercase — is `grok`, and it is run as `agent stdio`.
    static func isAcpCommand(_ executable: String, _ arguments: [String]) -> Bool {
        let slashed = executable.replacingOccurrences(of: "\\", with: "/")
        var name = slashed.split(separator: "/").last.map(String.init) ?? ""
        if let range = name.range(of: #"\.(cmd|exe|ps1)$"#, options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        return name.lowercased() == "grok" && arguments.count >= 2 && arguments[0] == "agent" && arguments[1] == "stdio"
    }

    /// acpx's `readAgentSpecificEnvCredential`: `XAI_API_KEY` for `xai.api_key`, when not blank.
    static func apiKey(for methodId: String, in environment: [String: String]) -> String? {
        guard methodId == apiKeyMethod, let value = environment["XAI_API_KEY"],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
#endif
