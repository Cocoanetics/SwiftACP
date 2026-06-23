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
    /// inherit the full parent environment, promote `ACPX_AUTH_*`, then inject
    /// the configured `auth` credentials.
    public static func forAgent(authCredentials: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        promotePrefixedAuth(&environment)
        for (methodId, credential) in authCredentials {
            assignAuthCredential(&environment, methodId: methodId, credential: credential)
        }
        return environment
    }

    /// For each `ACPX_AUTH_X`, also set bare `X` if it isn't already present.
    private static func promotePrefixedAuth(_ environment: inout [String: String]) {
        for (key, value) in Array(environment) {
            guard key.hasPrefix(authEnvPrefix),
                !value.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            let normalized = String(key.dropFirst(authEnvPrefix.count))
            guard !normalized.isEmpty, environment[normalized] == nil else { continue }
            environment[normalized] = value
        }
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
