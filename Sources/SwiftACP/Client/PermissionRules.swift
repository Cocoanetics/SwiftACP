import Foundation
import JSONFoundation

/// acpx's per-tool permission policy (`--permission-policy`, its `PermissionPolicy`):
/// rules that approve, deny or escalate a tool-call permission request ahead of the
/// permission mode.
///
/// A rule matches a request by its inferred or given kind, its title, its title's first
/// word, or the tool name its raw input carries — case-insensitively; `*` matches every
/// request. `autoDeny` is looked at first, then `autoApprove`, then `escalate`, then
/// `defaultAction`; a request none of them decides goes by the mode
/// (``ToolPermissionApproval``).
public struct PermissionRules: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case approve, deny, escalate
    }

    public var autoApprove: [String]?
    public var autoDeny: [String]?
    public var escalate: [String]?
    public var defaultAction: Action?

    public init(
        autoApprove: [String]? = nil, autoDeny: [String]? = nil, escalate: [String]? = nil,
        defaultAction: Action? = nil
    ) {
        self.autoApprove = autoApprove
        self.autoDeny = autoDeny
        self.escalate = escalate
        self.defaultAction = defaultAction
    }

    /// acpx's `matchPermissionPolicy`: the action for `request`, and the rule that chose
    /// it (none for `defaultAction`) — or `nil` when the policy leaves it to the mode.
    public func match(_ request: RequestPermissionRequest) -> (action: Action, rule: String?)? {
        let tokens = Self.matchTokens(of: request)
        func rule(in rules: [String]?) -> String? {
            rules?.first { rule in
                let normalized = rule.trimmedLikeJavaScript.lowercased()
                return normalized == "*" || tokens.contains(normalized)
            }
        }
        if let denied = rule(in: autoDeny) { return (.deny, denied) }
        if let approved = rule(in: autoApprove) { return (.approve, approved) }
        if let escalated = rule(in: escalate) { return (.escalate, escalated) }
        return defaultAction.map { ($0, nil) }
    }

    /// acpx's `permissionMatchTokens`: the inferred kind, the kind given, the title, the
    /// tool name and the title's first word — each trimmed and lowercased.
    static func matchTokens(of request: RequestPermissionRequest) -> Set<String> {
        let title = request.toolCall.title?.trimmedLikeJavaScript
        var tokens: Set<String> = []
        for value in [
            ToolPermissionApproval.inferredKind(of: request)?.rawValue, request.toolCall.kind?.rawValue,
            title, toolName(of: request), title.flatMap(titleHead)
        ] {
            guard let trimmed = value?.trimmedLikeJavaScript, !trimmed.isEmpty else { continue }
            tokens.insert(trimmed.lowercased())
        }
        return tokens
    }

    /// acpx's `readToolName`: the raw input's `name`, `tool` or `toolName`, else the
    /// title's first word.
    static func toolName(of request: RequestPermissionRequest) -> String? {
        if case .object(let input)? = request.toolCall.rawInput {
            for key in ["name", "tool", "toolName"] {
                if case .string(let name)? = input[key] {
                    let trimmed = name.trimmedLikeJavaScript
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return request.toolCall.title.flatMap { titleHead($0.trimmedLikeJavaScript) }
    }

    /// The title up to its first `:` or whitespace, trimmed; `nil` when that is empty.
    static func titleHead(_ title: String) -> String? {
        let head = title.split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == ":" || $0.isWhitespace }
            .first.map { String($0).trimmedLikeJavaScript } ?? ""
        return head.isEmpty ? nil : head
    }
}

/// A request a permission policy escalated, with nobody to ask — acpx's
/// `PermissionEscalationEvent`. It rides on the refusal as
/// `_meta.acpx.permissionEscalation`, so an orchestrator can resume with a broader
/// policy, and text output shows it as a `[permission]` notice.
public struct PermissionEscalation: Codable, Sendable, Hashable {
    public var type = "permission_escalation"
    public var sessionId: String
    public var toolCallId: String
    public var toolName: String?
    public var toolTitle: String
    public var toolInput: JSONValue?
    public var toolKind: String?
    public var action = "escalate"
    public var matchedRule: String?
    public var message: String
    public var timestamp: String

    /// acpx's `buildEscalationEvent`.
    public init(_ request: RequestPermissionRequest, matchedRule: String?, timestamp: String) {
        let title = request.toolCall.title?.trimmedLikeJavaScript ?? ""
        sessionId = request.sessionId
        toolCallId = request.toolCall.toolCallId
        toolName = PermissionRules.toolName(of: request)
        toolTitle = title.isEmpty ? "tool" : title
        toolInput = request.toolCall.rawInput
        toolKind = ToolPermissionApproval.inferredKind(of: request)?.rawValue
        self.matchedRule = matchedRule
        message = "Permission escalation required for \(toolTitle)"
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case type, sessionId, toolCallId, toolName, toolTitle, toolInput, toolKind, action, matchedRule
        case message, timestamp
    }
}

extension RequestPermissionResponse {
    /// The escalation the client attached under `_meta.acpx.permissionEscalation`, if any.
    public var permissionEscalation: PermissionEscalation? {
        guard let value = meta?["acpx"]?["permissionEscalation"] else { return nil }
        return try? value.decoded(PermissionEscalation.self)
    }
}

extension String {
    /// `String.prototype.trim`: JavaScript's whitespace and line terminators.
    var trimmedLikeJavaScript: String {
        trimmingCharacters(in: CharacterSet(
            charactersIn: "\t\n\u{0B}\u{0C}\r \u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
        ).union(CharacterSet(charactersIn: "\u{2000}"..."\u{200A}")))
    }
}
