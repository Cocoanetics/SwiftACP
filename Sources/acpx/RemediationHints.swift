import ACPXCore
import Foundation
import SwiftACP

// Ports `getTextErrorRemediationHints` from acpx's `src/cli/output/output.ts`:
// the `hint:` lines that can follow an `[error]` line, tailored to the failure.
// Used by the renderer's `renderError` (wire, acp-origin errors) and by the
// exec command's stderr error handler.

/// Port of acpx's `getTextErrorRemediationHints`: an `[error]` line may be
/// followed by `hint:` lines tailored to the failure — going by its codes, its
/// message, and the agent's error it carries (`acp`), if any.
func remediationHints(
    code: String, origin: String?, detailCode: String?, message: String, acp: AcpErrorPayload?
) -> [String] {
    let lower = message.lowercased()

    if detailCode == "AUTH_REQUIRED" { return [authRequiredHint(message: message, acp: acp)] }
    if code == "TIMEOUT" {
        return [
            "hint: increase `--timeout <seconds>` for long-running prompts, or check whether "
                + "the agent/provider is stalled."
        ]
    }
    if code == "NO_SESSION" { return noSessionHints(lower) }

    // First matching message-pattern rule wins (TEXT_ERROR_HINT_RULES order).
    if lower.contains("does not support session/resume") || lower.contains("does not support session/load") {
        return [
            "hint: this adapter cannot resume saved ACP sessions; create a fresh one with "
                + "`acpx <agent> sessions new` instead of reusing `--resume-session`."
        ]
    }
    if lower.contains("failed to resume acp session") || lower.contains("session/resume")
        || lower.contains("session/load") {
        return [
            "hint: rerun with `--verbose` to capture the ACP load failure details.",
            "hint: if you do not need the old backend session, start a fresh one with "
                + "`acpx <agent> sessions new` and retry."
        ]
    }
    if message.range(of: #"\b429\b"#, options: .regularExpression) != nil
        || lower.contains("rate limit") || lower.contains("quota exceeded") {
        return [
            "hint: the provider appears rate-limited; retry later, switch model, or check "
                + "provider quota/billing."
        ]
    }
    if lower.contains("model not found") || lower.contains("unknown model")
        || lower.contains("invalid model") {
        return [
            "hint: check the configured model name for this agent, then retry with "
                + "`--model <model>` or `sessions set-model <model>`."
        ]
    }
    if lower.contains("session/set_mode") || lower.contains("session/set_model")
        || lower.contains("session/set_config_option") {
        return ["hint: rerun with `--verbose` to capture the ACP method/error details before retrying."]
    }
    // isRuntimeAcpProtocolError: acp-origin RUNTIME with a protocol-level code.
    // Origin-gated, so it fires for the formatter (wire, acp origin) but not for
    // the CLI's stderr handler (non-acp origin).
    if origin == "acp", code == "RUNTIME",
        acp?.code == -32602 || acp?.code == -32603 || lower.contains("internal error") {
        return ["hint: rerun with `--verbose` to capture the underlying ACP error details."]
    }
    return []
}

private func noSessionHints(_ lower: String) -> [String] {
    if lower.contains("create one:") { return [] }
    return [
        "hint: the saved ACP session is missing or stale; start a fresh session with "
            + "`acpx <agent> sessions new`, then retry."
    ]
}

/// acpx's `renderAuthRequiredHint`: the `auth.<methodId>` keys to add, for the auth
/// methods the failure names — in the agent's error data, then in the message — or
/// the credential in general when it names none.
private func authRequiredHint(message: String, acp: AcpErrorPayload?) -> String {
    let methodIds = deduplicated(authMethodIds(in: acp?.data) + authMethodIds(in: message))
    guard !methodIds.isEmpty else {
        return "hint: run `acpx config show` to locate the active config, then add the required "
            + "credential under `auth` and retry."
    }
    let keys = methodIds.map { "`auth.\($0)`" }
    return "hint: run `acpx config show` to locate the active config, then add \(disjunction(keys)) and retry."
}

/// acpx's `parseAuthMethodIdsFromAcpData`: `methodId`, and each of `methods` — a string,
/// or an object's `id` — trimmed, when not blank.
private func authMethodIds(in data: WireJSON?) -> [String] {
    guard let data, case .object = data else { return [] }
    var ids: [String] = []
    if let methodId = data["methodId"]?.stringValue?.javaScriptTrimmed, !methodId.isEmpty {
        ids.append(methodId)
    }
    if case .array(let methods)? = data["methods"] {
        for entry in methods {
            let id = (entry.stringValue ?? entry["id"]?.stringValue)?.javaScriptTrimmed
            if let id, !id.isEmpty { ids.append(id) }
        }
    }
    return deduplicated(ids)
}

/// acpx's `parseAuthMethodIdsFromMessage`: the ids listed in `auth methods [a, b]`, then
/// the one in `auth method a` — each phrase matched in any case, at its first place.
private func authMethodIds(in message: String) -> [String] {
    let whole = NSRange(message.startIndex..., in: message)
    var ids: [String] = []
    if let list = authMethodList?.firstMatch(in: message, range: whole),
        let inner = Range(list.range(at: 1), in: message) {
        ids += message[inner].split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).javaScriptTrimmed }.filter { !$0.isEmpty }
    }
    if let single = authMethodName?.firstMatch(in: message, range: whole),
        let name = Range(single.range(at: 1), in: message) {
        ids.append(String(message[name]))
    }
    return deduplicated(ids)
}

/// `/auth methods \[([^\]]+)\]/iu`.
private let authMethodList = try? NSRegularExpression(
    pattern: #"auth methods \[([^\]]+)\]"#, options: .caseInsensitive)
/// `/auth method ([\w.-]+)/iu`. JavaScript's `\w` is ASCII; matching regardless of case
/// adds `ſ` and the Kelvin sign to it, as ICU's case closure of the class does here.
private let authMethodName = try? NSRegularExpression(
    pattern: #"auth method ([A-Za-z0-9_.\-]+)"#, options: .caseInsensitive)

/// acpx's `dedupeStrings` (`new Set`): each string once, where it first came — told
/// apart by their UTF-16 units, as JavaScript compares them.
private func deduplicated(_ values: [String]) -> [String] {
    var seen = Set<[UInt16]>()
    return values.filter { seen.insert(Array($0.utf16)).inserted }
}

/// acpx's `formatDisjunction`: `a`, `a or b`, `a, b, or c`.
private func disjunction(_ values: [String]) -> String {
    guard values.count > 2 else { return values.joined(separator: " or ") }
    return values.dropLast().joined(separator: ", ") + ", or " + (values.last ?? "")
}
