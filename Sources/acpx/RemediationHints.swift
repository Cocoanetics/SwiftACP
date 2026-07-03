import Foundation

// Ports `getTextErrorRemediationHints` from acpx's `src/cli/output/output.ts`:
// the `hint:` lines that can follow an `[error]` line, tailored to the failure.
// Used by the renderer's `renderError` (wire, acp-origin errors) and by the
// exec command's stderr error handler.

/// Port of acpx's `getTextErrorRemediationHints`: an `[error]` line may be
/// followed by `hint:` lines tailored to the failure. The message-pattern rules
/// are what turn errors reach today; the `TIMEOUT`/`NO_SESSION`/`AUTH_REQUIRED`
/// branches mirror acpx for when those classes are routed through the formatter.
func remediationHints(code: String, origin: String?, detailCode: String?, message: String, acpCode: Int?)
    -> [String] {
    let lower = message.lowercased()

    if detailCode == "AUTH_REQUIRED" { return [authRequiredHint] }
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
        acpCode == -32602 || acpCode == -32603 || lower.contains("internal error") {
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

/// acpx's `renderAuthRequiredHint` additionally names the `auth.<methodId>` keys
/// parsed from the error; that method-id extraction is not ported, so its
/// zero-methods (generic) form is used.
private let authRequiredHint =
    "hint: run `acpx config show` to locate the active config, then add the required "
        + "credential under `auth` and retry."
