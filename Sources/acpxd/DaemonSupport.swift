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
    case sessionBusy(String)

    var errorDescription: String? {
        switch self {
        case .invalidCwd(let path):
            return "cwd does not exist or is not a directory: \(path)"
        case .emptySessionId:
            return "sessionId must not be empty — create one with the newSession tool first"
        case .sessionNotFound(let id):
            return "no session found for id: \(id)"
        case .sessionBusy(let id):
            return "session is busy running another turn (use --wait to queue): \(id)"
        }
    }
}
