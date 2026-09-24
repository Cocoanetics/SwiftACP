import Foundation
import JSONFoundation

// The two events that frame the end of a daemon turn, streamed to the calling client as
// MCP log notifications: the prompt's answer, and the turn's end once it is over. Split
// from `DaemonDTOs.swift` to keep that file inside the 500-line limit.

/// The turn's terminal event, streamed as a final MCP log notification.
///
/// The `runPrompt` tool result is the agent's aggregate response *text* (so an MCP
/// client gets the actual answer, not a status token). The stop reason is therefore
/// demoted to a streamed event: the daemon sends one ``TurnEndedEvent`` once the turn
/// ends, right after the last `session/update` and before the tool returns. A prompt
/// the agent answered was announced at its answer before (``TurnAnsweredEvent``).
public struct TurnEndedEvent: Codable, Sendable {
    /// The raw ACP stop reason (e.g. `end_turn`, `refusal`, `cancelled`).
    public var stopReason: String
    /// How the turn's permissions were settled, which decides the CLI's exit code
    /// (`PERMISSION_DENIED`, 5): read once the turn is over — the agent's requests from
    /// it answered, its updates gone quiet — as acpx reads them for its result
    /// (`toPromptResult`). `nil` from a daemon that predates it.
    public var permissions: PermissionStats?
    /// The prompt response's `usage` and `cost` as the agent sent them, whatever their
    /// shape — what acpx's quiet output reports after the reply.
    public var usage: JSONValue?
    public var cost: JSONValue?

    public init(
        stopReason: String, permissions: PermissionStats? = nil, usage: JSONValue? = nil, cost: JSONValue? = nil
    ) {
        self.stopReason = stopReason
        self.permissions = permissions
        self.usage = usage
        self.cost = cost
    }
}

/// The prompt's answer, streamed as a log notification as soon as it arrives: where
/// acpx's formatters mark the turn done. The turn goes on — the agent's updates after
/// its answer, the requests from it still open — until its ``TurnEndedEvent``.
public struct TurnAnsweredEvent: Codable, Sendable {
    /// The raw ACP stop reason the prompt was answered with. Named apart from every other
    /// event's fields, so no event decodes as another.
    public var answeredStopReason: String

    public init(answeredStopReason: String) {
        self.answeredStopReason = answeredStopReason
    }
}
