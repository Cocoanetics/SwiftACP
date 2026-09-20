import Foundation

/// Compatibility rules for the Codex ACP adapter (`@agentclientprotocol/codex-acp`),
/// applied at the client boundary where its option ids have verified meanings — a
/// port of acpx's `src/acp/codex-compat.ts` (openclaw/acpx#608, fixing #535).
///
/// Codex can offer two `reject_once` options whose consequences differ enormously:
/// `decline` ("No, continue without running it") fails just the tool call and the
/// turn continues, while `cancel` ("No, and tell Codex what to do differently") maps
/// to `ReviewDecision::Abort` and interrupts the whole turn. Sandbox-escalation
/// prompts offer *only* `cancel`. Picking a refusal by kind alone therefore lands on
/// whichever Codex listed first, so a `--deny-all` run — or a human answering "no" to
/// one command — could silently end a long turn.
///
/// The connection applies these rules around every permission handler: it ranks the
/// non-aborting refusal first before the handler picks, and when the refusal it
/// sends may still end the turn it says so — as a ``ClientOperation`` on the event
/// subscriptions and as `_meta.acpx.permissionNotice` on the response. No operation
/// is ever approved to keep a turn running.
public enum CodexCompat {
    /// The `agentInfo.name` the verified Codex ACP adapter reports in `initialize`.
    public static let agentName = "@agentclientprotocol/codex-acp"

    /// Codex's one-time refusal ids that fail the tool call but let the turn continue.
    public static let continuingRefusalIds: Set<String> = ["decline", "reject_permissions"]

    /// Codex's one-time refusal id that interrupts the whole turn.
    public static let abortingRefusalId = "cancel"

    /// Rank Codex's non-aborting one-time refusal first, so kind-based selection
    /// (``PermissionPolicy/reject(_:)``, or any resolver taking the first
    /// `reject_once`) lands on it. Any other adapter's request — and a Codex request
    /// with no such option — is returned unchanged, keeping the generic kind-based
    /// contract and other adapters' opaque option ids intact. Approval options keep
    /// their relative order.
    public static func preferPermissionRefusal(
        _ request: RequestPermissionRequest, agentName: String?
    ) -> RequestPermissionRequest {
        guard agentName == Self.agentName,
            let index = request.options.firstIndex(where: {
                $0.kind == .rejectOnce && continuingRefusalIds.contains($0.optionId)
            })
        else { return request }
        var ranked = request
        let preferred = ranked.options.remove(at: index)
        ranked.options.insert(preferred, at: 0)
        return ranked
    }

    /// The notice to surface when a Codex permission response may end the turn: the
    /// response selected Codex's `cancel` refusal, or cancelled the request outright
    /// because no matching option existed. `nil` for any other adapter, for approvals,
    /// and for refusals that let the turn continue.
    public static func permissionNotice(
        request: RequestPermissionRequest, response: RequestPermissionResponse, agentName: String?
    ) -> String? {
        guard agentName == Self.agentName else { return nil }
        switch response.outcome {
        case .cancelled:
            return "No matching permission option was available. The request was safely cancelled; "
                + "Codex may end the current turn."
        case .selected(let optionId):
            let option = request.options.first { $0.optionId == optionId }
            guard option?.kind == .rejectOnce, optionId == abortingRefusalId else { return nil }
            return "Permission refused using Codex's cancellation option; this can end the current turn. "
                + "The operation was not approved."
        }
    }
}
