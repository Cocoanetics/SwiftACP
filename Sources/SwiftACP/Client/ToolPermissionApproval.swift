import Foundation

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
public struct ToolPermissionApproval: Sendable {
    public let policy: PermissionPolicy
    public let nonInteractive: NonInteractivePermissionPolicy
    private let prompt: TerminalPermissionPrompt

    /// - Parameter terminal: where to ask — the process's own terminal unless told
    ///   otherwise. ``TerminalPermissionPrompt/none`` never asks.
    public init(
        policy: PermissionPolicy, nonInteractive: NonInteractivePermissionPolicy = .deny,
        terminal: TerminalPermissionPrompt = .shared
    ) {
        self.policy = policy
        self.nonInteractive = nonInteractive
        self.prompt = terminal
    }

    /// Answer `request`, or throw ``PermissionPromptUnavailableError``.
    public func resolve(_ request: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        if case .custom(let resolver) = policy { return await resolver(request) }
        let options = request.options
        guard let first = options.first else { return .cancelled }
        let allow = PermissionPolicy.pick(options, [.allowOnce, .allowAlways])
        let reject = PermissionPolicy.pick(options, [.rejectOnce, .rejectAlways])
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
            let (title, label) = (request.toolCall.title ?? "tool", (kind ?? .other).rawValue)
            let question = "\n[permission] Allow \(title) [\(label)]? (y/N) "
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
    }

    /// acpx's `inferToolKind`: the kind the request gives, else the one its title's
    /// first word names — `other` when it names none, `nil` without a title.
    public static func inferredKind(of request: RequestPermissionRequest) -> ToolKind? {
        if let kind = request.toolCall.kind, !kind.rawValue.isEmpty { return kind }
        guard let title = request.toolCall.title?.javaScriptTrimmedForKind.lowercased(), !title.isEmpty
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

extension String {
    /// `String.prototype.trim` for a tool title: JavaScript's whitespace and line
    /// terminators.
    fileprivate var javaScriptTrimmedForKind: String {
        trimmingCharacters(in: CharacterSet(
            charactersIn: "\t\n\u{0B}\u{0C}\r \u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
        ).union(CharacterSet(charactersIn: "\u{2000}"..."\u{200A}")))
    }
}
