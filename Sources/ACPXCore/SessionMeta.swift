import Foundation
import JSONFoundation
import SwiftACP

/// The `_meta` block acpx puts on `session/new`, ported from
/// `acp/agent-command.ts` (`buildClaudeCodeOptionsMeta`,
/// `resolveClaudeCodeSettingSources`, `isClaudeAcpCommand`).
///
/// Despite the `claudeCode` key, this is **not** claude-only: acpx builds the
/// block from the invocation's session options whatever the agent is, and only
/// `settingSources` is gated on the adapter being Claude Code's. An adapter that
/// doesn't recognize the key ignores it; one that forwards `_meta` sees the same
/// request from acpx and from here.
public enum SessionMeta {
    /// Claude Code's setting sources, minus `user` — acpx isolates an automated
    /// run from the operator's personal settings unless asked not to.
    static let defaultClaudeSettingSources = ["project", "local"]

    /// Build the `_meta` for a `session/new`, or `nil` when nothing goes in it.
    ///
    /// `model`, `allowedTools` and `maxTurns` sit under `claudeCode.options`;
    /// `systemPrompt` sits at the **top level** of `_meta`, not beside them.
    public static func build(
        options: SessionAcpxState.SessionOptions?,
        agentCommand: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> JSONValue? {
        var claudeCodeOptions: [(String, JSONValue)] = []
        if let model = options?.model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            claudeCodeOptions.append(("model", .string(model)))
        }
        if let allowedTools = options?.allowedTools {
            claudeCodeOptions.append(("allowedTools", .array(allowedTools.map(JSONValue.string))))
        }
        if let maxTurns = options?.maxTurns {
            claudeCodeOptions.append(("maxTurns", .integer(maxTurns)))
        }
        if AgentCommandShape.isClaudeAcpCommand(agentCommand) {
            claudeCodeOptions.append(
                ("settingSources", .array(settingSources(environment).map(JSONValue.string))))
        }

        var meta: [(String, JSONValue)] = []
        if !claudeCodeOptions.isEmpty {
            meta.append(("claudeCode", .object(["options": objectPreservingOrder(claudeCodeOptions)])))
        }
        if let systemPrompt = normalizedSystemPrompt(options?.systemPrompt) {
            meta.append(("systemPrompt", systemPrompt))
        }
        // Not `meta.isEmpty ? nil : …`: `JSONValue` is `ExpressibleByNilLiteral`,
        // so a ternary unifies the branches on `JSONValue` and that `nil` becomes
        // `.null` — which would put a literal `"_meta": null` on the wire.
        if meta.isEmpty { return nil }
        return objectPreservingOrder(meta)
    }

    /// acpx's `resolveClaudeCodeSettingSources`: `user` is prepended only when
    /// `ACPX_CLAUDE_INCLUDE_USER_SETTINGS` is exactly `1` after trimming.
    static func settingSources(_ environment: [String: String]) -> [String] {
        let requested = environment["ACPX_CLAUDE_INCLUDE_USER_SETTINGS"]?
            .trimmingCharacters(in: .whitespaces)
        return requested == "1" ? ["user"] + defaultClaudeSettingSources : defaultClaudeSettingSources
    }

    /// A system prompt reaches `_meta` only in the two shapes acpx recognizes: a
    /// non-empty string, or `{ "append": <non-empty string> }`. Anything else —
    /// including an empty string or an empty append — is dropped.
    private static func normalizedSystemPrompt(_ value: JSONValue?) -> JSONValue? {
        switch value {
        case .string(let text):
            if text.isEmpty { return nil }
            return .string(text)
        case .object(let object):
            guard case .string(let append)? = object["append"], !append.isEmpty else { return nil }
            return .object(["append": .string(append)])
        default:
            return nil
        }
    }

    private static func objectPreservingOrder(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }
}
