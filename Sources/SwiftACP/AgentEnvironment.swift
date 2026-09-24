import Foundation

/// Builds the environment handed to a spawned agent subprocess, faithful to
/// acpx's `buildAgentEnvironment` (`acp/auth-env.ts`): the agent inherits the
/// full parent environment, then `ACPX_AUTH_*` variables are promoted and the
/// configured `auth` credentials are injected. Nothing is stripped — matching
/// acpx exactly (so e.g. an inherited `CLAUDE_CODE_OAUTH_TOKEN` passes through).
public enum AgentEnvironment {
    // MARK: - Auth credential injection (acpx `acp/auth-env.ts`)

    /// Prefix for environment variables acpx promotes into the agent (e.g.
    /// `ACPX_AUTH_OPENAI_API_KEY` → also set as `OPENAI_API_KEY`).
    public static let authEnvPrefix = "ACPX_AUTH_"

    /// Normalize an auth method id to an env-token: trim, collapse runs of
    /// non-alphanumeric to `_`, strip leading/trailing `_`, uppercase.
    public static func toEnvToken(_ value: String) -> String {
        var result = ""
        var inGap = false
        for character in value.trimmingCharacters(in: .whitespacesAndNewlines) {
            let isAlnum =
                character.isASCII
                && (("a" ... "z").contains(character) || ("A" ... "Z").contains(character)
                    || ("0" ... "9").contains(character))
            if isAlnum {
                if inGap { result.append("_"); inGap = false }
                result.append(character)
            } else {
                inGap = true
            }
        }
        while result.hasPrefix("_") { result.removeFirst() }
        while result.hasSuffix("_") { result.removeLast() }
        return result.uppercased()
    }

    /// The agent's environment, exactly like acpx's `buildAgentEnvironment`:
    /// inherit the full parent environment, promote `ACPX_AUTH_*`, inject the
    /// configured `auth` credentials, then lay the session's own variables over it —
    /// all but the credential variables acpx manages, which a session cannot replace.
    public static func forAgent(
        authCredentials: [String: String] = [:], sessionEnv: [String: String]? = nil
    ) -> [String: String] {
        forAgent(authCredentials: authCredentials, sessionEnv: sessionEnv, over: ProcessInfo.processInfo.environment)
    }

    /// ``forAgent(authCredentials:sessionEnv:)`` over `base` rather than this process's
    /// environment.
    static func forAgent(
        authCredentials: [String: String], sessionEnv: [String: String]?, over base: [String: String]
    ) -> [String: String] {
        var environment = base
        var managed = promotePrefixedAuth(&environment)
        for (methodId, credential) in authCredentials {
            managed.formUnion(credentialKeys(methodId: methodId, credential: credential))
            assignAuthCredential(&environment, methodId: methodId, credential: credential)
        }
        for (key, value) in sessionEnv ?? [:] where !managed.contains(key) {
            environment[key] = value
        }
        return environment
    }

    /// For each `ACPX_AUTH_X` with a value, also set `X` — the suffix as an env-token
    /// — unless it is set already. Returns the variables this manages: both names.
    private static func promotePrefixedAuth(_ environment: inout [String: String]) -> Set<String> {
        var managed: Set<String> = []
        for (key, value) in Array(environment) {
            guard key.hasPrefix(authEnvPrefix), !isBlank(value) else { continue }
            let normalized = toEnvToken(String(key.dropFirst(authEnvPrefix.count)))
            guard !normalized.isEmpty else { continue }
            managed.formUnion([key, normalized])
            if environment[normalized] == nil { environment[normalized] = value }
        }
        return managed
    }

    /// acpx's `addAuthCredentialEnvKeys`: the variables a configured credential sets.
    private static func credentialKeys(methodId: String, credential: String) -> Set<String> {
        guard !isBlank(credential) else { return [] }
        var keys: Set<String> = []
        if !methodId.contains("=") && !methodId.contains("\0") { keys.insert(methodId) }
        let token = toEnvToken(methodId)
        if !token.isEmpty { keys.formUnion(["\(authEnvPrefix)\(token)", token]) }
        return keys
    }

    /// `value.trim().length === 0`.
    private static func isBlank(_ value: String) -> Bool {
        TerminalOutputLimit.javaScriptTrimmed(value).isEmpty
    }

    private static func assignAuthCredential(
        _ environment: inout [String: String], methodId: String, credential: String
    ) {
        guard !credential.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if !methodId.contains("=") && !methodId.contains("\0") && environment[methodId] == nil {
            environment[methodId] = credential
        }
        let token = toEnvToken(methodId)
        guard !token.isEmpty else { return }
        if environment["\(authEnvPrefix)\(token)"] == nil {
            environment["\(authEnvPrefix)\(token)"] = credential
        }
        if environment[token] == nil { environment[token] = credential }
    }

    /// A credential for `methodId` from this process's `ACPX_AUTH_<token>` env var.
    public static func readEnvCredential(methodId: String) -> String? {
        let token = toEnvToken(methodId)
        guard !token.isEmpty,
            let value = ProcessInfo.processInfo.environment["\(authEnvPrefix)\(token)"],
            !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return value
    }

    /// A credential for `methodId` from configured `auth` (by id, then env-token).
    public static func resolveConfiguredAuthCredential(
        methodId: String, authCredentials: [String: String]
    ) -> String? {
        authCredentials[methodId] ?? authCredentials[toEnvToken(methodId)]
    }
}

/// Raised when the agent advertises auth methods, no matching credential is
/// found, and the auth policy is `fail` (acpx `AuthPolicyError`).
public struct AuthPolicyError: Error, CustomStringConvertible {
    public let methodIds: [String]
    public var description: String {
        "agent advertised auth methods [\(methodIds.joined(separator: ", "))] "
            + "but no matching credentials found"
    }
}
