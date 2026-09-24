import Foundation
import JSONFoundation

/// A tool-call permission needed an answer that could not be asked for, and the policy
/// is ``NonInteractivePermissionPolicy/fail`` — acpx's `PermissionPromptUnavailableError`.
/// The connection answers the request `cancelled`, and the turn fails on it once over.
public struct PermissionPromptUnavailableError: Error, Sendable, Equatable, CustomStringConvertible {
    public init() {}

    public var description: String { "Permission prompt unavailable in non-interactive mode" }
}

/// How a `session/request_permission` is answered under a permission mode — acpx's
/// `resolvePermissionRequest` (`src/permissions.ts`):
///
/// | mode | outcome |
/// |---|---|
/// | ``PermissionPolicy/approveAll`` | the allow option, else the first |
/// | ``PermissionPolicy/denyAll`` | the reject option, else cancelled |
/// | ``PermissionPolicy/approveReads`` | a read or search: the allow option. Anything else is asked on the terminal, or, with none, follows ``NonInteractivePermissionPolicy`` |
///
/// The kind is the request's, else inferred from the title (``inferredKind(of:)``).
/// ``PermissionPolicy/custom(_:)`` answers for itself.
///
/// A permission policy (``PermissionRules``, `--permission-policy`) comes first: it
/// approves, denies, or escalates — asks on the terminal, or, with none, refuses with
/// the escalation attached (``PermissionEscalation``).
public struct ToolPermissionApproval: Sendable {
    public let policy: PermissionPolicy
    public let nonInteractive: NonInteractivePermissionPolicy
    public let rules: PermissionRules?
    private let prompt: TerminalPermissionPrompt

    /// - Parameter terminal: where to ask — the process's own terminal unless told
    ///   otherwise. ``TerminalPermissionPrompt/none`` never asks.
    public init(
        policy: PermissionPolicy, nonInteractive: NonInteractivePermissionPolicy = .deny,
        rules: PermissionRules? = nil, terminal: TerminalPermissionPrompt = .shared
    ) {
        self.policy = policy
        self.nonInteractive = nonInteractive
        self.rules = rules
        self.prompt = terminal
    }

    /// Answer `request`, or throw ``PermissionPromptUnavailableError``.
    public func resolve(_ request: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        if case .custom(let resolver) = policy { return await resolver(request) }
        let options = request.options
        guard let first = options.first else { return .cancelled }
        let allow = PermissionPolicy.pick(options, [.allowOnce, .allowAlways])
        let reject = PermissionPolicy.pick(options, [.rejectOnce, .rejectAlways])
        if let (action, rule) = rules?.match(request) {
            switch action {
            case .approve:
                return .selected((allow ?? first).optionId)
            case .deny:
                return reject.map { .selected($0.optionId) } ?? .cancelled
            case .escalate:
                if prompt.canPrompt { return await ask(request, allow: allow, reject: reject) }
                let escalation = PermissionEscalation(request, matchedRule: rule, timestamp: Self.now())
                let refusal = reject.map { RequestPermissionResponse.selected($0.optionId) } ?? .cancelled
                let attached = (try? JSONValue(encoding: escalation)) ?? .null
                return refusal.addingACPXMetadata(["permissionEscalation": attached])
            }
        }
        switch policy {
        case .approveAll:
            return .selected((allow ?? first).optionId)
        case .denyAll:
            return reject.map { .selected($0.optionId) } ?? .cancelled
        case .approveReads, .custom:
            let kind = Self.inferredKind(of: request)
            if kind == .read || kind == .search, let allow { return .selected(allow.optionId) }
            guard prompt.canPrompt else {
                if nonInteractive == .fail { throw PermissionPromptUnavailableError() }
                return reject.map { .selected($0.optionId) } ?? .cancelled
            }
            return await ask(request, allow: allow, reject: reject)
        }
    }

    /// acpx's `resolveInteractivePromptResult`: the question on the terminal, and the
    /// option the answer picks.
    private func ask(
        _ request: RequestPermissionRequest, allow: PermissionOption?, reject: PermissionOption?
    ) async -> RequestPermissionResponse {
        let kind = Self.inferredKind(of: request) ?? .other
        let question = "\n[permission] Allow \(request.toolCall.title ?? "tool") [\(kind.rawValue)]? (y/N) "
        let approved: Bool
        do {
            approved = try await prompt.ask(prompt: question)
        } catch {
            return .cancelled
        }
        if approved, let allow { return .selected(allow.optionId) }
        if !approved, let reject { return .selected(reject.optionId) }
        return .cancelled
    }

    /// An ISO 8601 timestamp with milliseconds, as `Date.prototype.toISOString`.
    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// acpx's `inferToolKind`: the kind the request gives, else the one its title's
    /// first word names — `other` when it names none, `nil` without a title.
    public static func inferredKind(of request: RequestPermissionRequest) -> ToolKind? {
        if let kind = request.toolCall.kind, !kind.rawValue.isEmpty { return kind }
        guard let title = request.toolCall.title?.trimmedLikeJavaScript.lowercased(), !title.isEmpty
        else { return nil }
        let head = title.split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == ":" || $0.isWhitespace }
            .first.map(String.init) ?? ""
        guard !head.isEmpty else { return nil }
        return titleKinds.first { $0.names.contains(head) }?.kind ?? .other
    }

    /// acpx's `TOOL_KIND_TITLE_MATCHERS`.
    static let titleKinds: [(kind: ToolKind, names: [String])] = [
        (.read, ["read", "cat"]),
        (.search, ["search", "find", "grep"]),
        (.edit, ["write", "edit", "patch"]),
        (.delete, ["delete", "remove"]),
        (.move, ["move", "rename"]),
        (.execute, ["run", "execute", "bash"]),
        (.fetch, ["fetch", "http", "url"]),
        (.think, ["think"])
    ]
}
