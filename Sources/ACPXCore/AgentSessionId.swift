import Foundation
import JSONFoundation

/// The agent's own id for a session, as it names it in the `_meta` of the replies that
/// open one (`session/new`, `session/load`, `session/resume`) — acpx's
/// `src/acp/agent-session-id.ts`. acpx records it as `agent_session_id`.
public enum AgentSessionId {
    /// `normalizeAgentSessionId`: a string, trimmed, and not empty.
    public static func normalize(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        let trimmed = text.javaScriptTrimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `extractAgentSessionId`: `_meta.agentSessionId`, else `_meta.sessionId`.
    public static func extract(from meta: JSONValue?) -> String? {
        guard case .object(let fields)? = meta else { return nil }
        return normalize(fields["agentSessionId"]) ?? normalize(fields["sessionId"])
    }
}

extension SessionRecord {
    /// acpx's `reconcileAgentSessionId`: an id replaces the recorded one; none keeps it.
    public mutating func reconcileAgentSessionId(_ id: String?) {
        guard let id = AgentSessionId.normalize(id.map(JSONValue.string)) else { return }
        agentSessionId = id
    }
}
