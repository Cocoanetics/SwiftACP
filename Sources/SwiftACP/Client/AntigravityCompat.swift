import Foundation

/// Compatibility rules for Google's Antigravity ACP server, applied at the client
/// boundary — a port of acpx's Antigravity guard in `src/acp/client.ts`, introduced in
/// acpx 0.17.1 as a deliberate breaking change.
///
/// Antigravity encodes its *interaction questions* as permission requests: the answers
/// arrive as options marked `allow_once`. A permission mode or a host resolver picking
/// "the approval" would therefore be answering a question meant for a person — choosing
/// on their behalf, silently, and `--approve-all` would do it every time.
///
/// No automatic answer is safe, so the client cancels these requests outright, ahead of
/// any policy or handler, and says why: as a ``ClientOperation`` on the event
/// subscriptions and as `_meta.acpx.permissionNotice` on the response. This takes
/// precedence over every permission mode, including a host's own resolver.
public enum AntigravityCompat {
    /// The `agentInfo.name` Antigravity's ACP server reports in `initialize`. The rule
    /// keys on what the adapter reports rather than on the registry name, so a custom
    /// launcher pointed at the same binary is covered too.
    public static let agentName = "antigravity-acp"

    /// The tool-call id prefix Antigravity gives an interaction question.
    public static let questionToolCallIdPrefix = "interaction_"

    /// Whether `request` is an Antigravity interaction question rather than a permission
    /// decision. `false` for every other adapter, so an `interaction_`-prefixed id from
    /// elsewhere keeps its ordinary handling.
    public static func isInteractionQuestion(
        _ request: RequestPermissionRequest, agentName: String?
    ) -> Bool {
        agentName == Self.agentName
            && request.toolCall.toolCallId.hasPrefix(questionToolCallIdPrefix)
    }

    /// Why the question was cancelled instead of answered — acpx's wording, expanded
    /// with the remedy it gives.
    public static let questionNotice =
        "Antigravity requested a user answer. Its interaction questions arrive as permission "
        + "requests, so no permission mode or handler can answer them; the request was "
        + "cancelled and nothing was approved. Continue this conversation in an interactive "
        + "client that supports Antigravity questions."
}
