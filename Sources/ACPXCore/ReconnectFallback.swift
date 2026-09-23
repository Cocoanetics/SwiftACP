import Foundation
import JSONFoundation
import SwiftACP

/// When a failed reconnect may be replaced by a brand-new session — acpx's
/// `shouldFallbackToNewSession` (`runtime/engine/reconnect.ts`) and the
/// session-not-found detection it relies on (`acp/error-shapes.ts`).
///
/// Starting over is not harmless: the new session has none of the conversation, yet
/// the record keeps the old id, so later turns would silently run without their
/// context. acpx therefore only does it when the old session is plainly gone or the
/// agent cannot reload sessions — or, for a generic internal error, when there was no
/// conversation to lose. Anything else is surfaced rather than papered over.
public enum ReconnectFallback {
    /// JSON-RPC's method-not-found and invalid-params: the agent cannot load this way.
    static let unsupportedLoadCodes: Set<Int> = [-32601, -32602]
    /// The codes agents answer a missing session with.
    static let resourceNotFoundCodes: Set<Int> = [-32001, -32002]

    /// Whether to start a fresh session after reconnecting failed with `error`.
    ///
    /// - Parameter sessionHasAgentMessages: whether the record holds any agent reply —
    ///   a session with nothing to lose may be replaced after a generic internal error.
    public static func shouldStartFresh(after error: Error, sessionHasAgentMessages: Bool) -> Bool {
        // A cancelled reconnect is not the agent's answer about the session.
        if error is CancellationError { return false }
        let code = (error as? JSONRPCErrorBody)?.code
        if isResourceNotFound(error) { return true }
        if let code, unsupportedLoadCodes.contains(code) { return true }
        return !sessionHasAgentMessages && code == -32603
    }

    /// acpx's `isAcpResourceNotFoundError`: a not-found code, or session-not-found
    /// wording in the message, anywhere in the error's data, or — for an error that did
    /// not come from the agent — in its description.
    public static func isResourceNotFound(_ error: Error) -> Bool {
        guard let acp = error as? JSONRPCErrorBody else {
            return isSessionNotFoundText(error.localizedDescription)
        }
        if resourceNotFoundCodes.contains(acp.code) { return true }
        if isSessionNotFoundText(acp.message) { return true }
        return hasSessionNotFoundHint(acp.data, depth: 0)
    }

    /// acpx's `isSessionNotFoundText`.
    static func isSessionNotFoundText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let phrases = [
            "resource_not_found", "resource not found", "session not found", "unknown session",
            "invalid session identifier"
        ]
        if phrases.contains(where: lowered.contains) { return true }
        // "session" then an id (quoted or not) then "not found": `Session "abc" not found`.
        return text.range(
            of: #"session\s+["'\w-]+\s+not found"#, options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// acpx's `hasSessionNotFoundHint`: search the error's data, four levels deep.
    static func hasSessionNotFoundHint(_ value: JSONValue?, depth: Int) -> Bool {
        guard depth <= 4, let value else { return false }
        switch value {
        case .string(let text): return isSessionNotFoundText(text)
        case .array(let items): return items.contains { hasSessionNotFoundHint($0, depth: depth + 1) }
        case .object(let fields):
            return fields.values.contains { hasSessionNotFoundHint($0, depth: depth + 1) }
        default: return false
        }
    }
}

extension SessionRecord {
    /// acpx's `sessionHasAgentMessages`: whether the conversation holds any agent reply.
    public var hasAgentMessages: Bool {
        messages.contains { if case .agent = $0 { return true } else { return false } }
    }
}
