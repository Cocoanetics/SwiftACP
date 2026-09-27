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
                // Named as acpx's `selectAuthMethod` finds it: in the client's own environment
                // first, then in the config — which the agent's environment carries too.
                let fromCaller = AgentEnvironment.readEnvCredential(methodId: method.id, in: callerEnvironment) != nil
                log.log("authenticated with method \(method.id) (\(fromCaller || !hasConfig ? "env" : "config"))")
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
}
#endif
