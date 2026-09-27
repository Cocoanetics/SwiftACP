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
        log: RawWireTap
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
#endif
