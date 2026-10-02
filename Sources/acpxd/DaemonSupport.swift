import ACPXCore
import Foundation
import JSONFoundation

/// Encodes any `Encodable` to a `JSONValue` (for MCP log-notification payloads).
func toJSONValue<T: Encodable>(_ value: T) -> JSONValue {
    (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        ?? .null
}

/// Errors surfaced to MCP clients as the tool result's error text
/// (`error.localizedDescription`), so they're actionable rather than opaque.
enum DaemonError: LocalizedError {
    case invalidCwd(String)
    case emptySessionId
    case sessionNotFound(String)
    case multipleSessionsMatch(String)
    case ambiguousSessionId(String)
    case sessionBusy(String)
    case invalidPermissionMode(String)
    case invalidNonInteractivePermissions(String)
    case invalidPromptRetries(Int)
    case invalidTimeout(Int)
    case invalidTTL(Int)
    case sessionResumeRequired(String, reason: String, cause: Error? = nil)
    case stopping

    var errorDescription: String? {
        switch self {
        case .invalidCwd(let path):
            return "cwd does not exist or is not a directory: \(path)"
        case .emptySessionId:
            return "sessionId must not be empty — create one with the newSession tool first"
        case .sessionNotFound(let id):
            return "no session found for id: \(id)"
        case .multipleSessionsMatch(let id):
            // acpx's SessionResolutionError wording (resolveSessionRecord).
            return "Multiple sessions match id: \(id)"
        case .ambiguousSessionId(let id):
            return "Session id is ambiguous: \(id)"
        case .sessionBusy(let id):
            return "session is busy running another turn (use --wait to queue): \(id)"
        case .invalidPermissionMode(let mode):
            return "invalid permissionMode \"\(mode)\": expected approve-all, approve-reads or deny-all"
        case .invalidNonInteractivePermissions(let policy):
            return "invalid nonInteractivePermissions \"\(policy)\": expected deny or fail"
        case .invalidPromptRetries(let retries):
            return "invalid promptRetries \(retries): expected a non-negative integer"
        case .invalidTimeout(let milliseconds):
            return "invalid timeoutMs \(milliseconds): exceeds the maximum supported timer delay"
        case .invalidTTL(let milliseconds):
            return "invalid ttlMs \(milliseconds): exceeds the maximum supported timer delay"
        case .sessionResumeRequired(let id, let reason, _):
            // npm acpx's SessionResumeRequiredError wording.
            return "Persistent ACP session \(id) could not be resumed: \(reason)"
        case .stopping:
            return "acpxd is stopping and starts no more agents"
        }
    }
}

/// acpx's `SessionResumeRequiredError` keeps what refused the session as its `cause`, where
/// acpx's output finds the agent's error (`extractAcpError`, #290).
extension DaemonError: ErrorWithCause {
    var cause: Error? {
        if case .sessionResumeRequired(_, _, let cause) = self { return cause }
        return nil
    }
}

extension DaemonError: OutputErrorMeta {
    /// acpx's `SessionResumeRequiredError` carries its own codes; the rest are runtime
    /// failures — its `SessionNotFoundError` and `SessionResolutionError` among them, which
    /// name no code of their own.
    var outputCode: String? {
        if case .sessionResumeRequired = self { return "RUNTIME" }
        return nil
    }

    var detailCode: String? {
        if case .sessionResumeRequired = self { return "SESSION_RESUME_REQUIRED" }
        return nil
    }

    var origin: String? {
        if case .sessionResumeRequired = self { return "acp" }
        return nil
    }

    var retryable: Bool? {
        if case .sessionResumeRequired = self { return true }
        return nil
    }
}
