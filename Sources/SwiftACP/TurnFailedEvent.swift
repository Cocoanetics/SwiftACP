import Foundation
import JSONFoundation

/// How a turn failed, streamed as the turn's last log notification before `runPrompt`
/// fails: what acpx's queue owner tells its CLI (`sendQueuedTaskError`), so the CLI can
/// report the failure the way acpx's formatters do.
///
/// The fields are acpx's normalized error (`normalizeOutputError`): the output code
/// decides the exit code, and `acp` is the JSON-RPC error on the wire that the failure
/// is — the agent's error response, or a refusal the client sent.
public struct TurnFailedEvent: Codable, Sendable, Equatable {
    /// acpx's output code: `RUNTIME`, `NO_SESSION`, `TIMEOUT`, `PERMISSION_DENIED`, …
    public var outputCode: String
    /// acpx's detail code, e.g. `QUEUE_RUNTIME_PROMPT_FAILED` or `AGENT_DISCONNECTED`.
    public var detailCode: String?
    /// Where the failure arose: `runtime`, `acp`, `queue`, …
    public var origin: String?
    public var message: String
    /// The JSON-RPC error the failure is, as `{code, message, data}`, when it is one.
    public var acp: JSONValue?
    /// Whether the wire already showed it — acpx's `outputAlreadyEmitted`: text and
    /// JSON output then add nothing for it.
    public var shown: Bool
    /// The acpx record id of the session, which acpx's JSON error line names.
    public var sessionId: String

    public init(
        outputCode: String, detailCode: String?, origin: String?, message: String, acp: JSONValue?,
        shown: Bool, sessionId: String
    ) {
        self.outputCode = outputCode
        self.detailCode = detailCode
        self.origin = origin
        self.message = message
        self.acp = acp
        self.shown = shown
        self.sessionId = sessionId
    }
}
