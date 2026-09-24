import Foundation

/// What a permission that needs confirmation does when there is no terminal to ask
/// on — acpx's `nonInteractivePermissions` (`--non-interactive-permissions`).
public enum NonInteractivePermissionPolicy: String, Sendable {
    /// Refuse it, as if the user had answered no. acpx's default.
    case deny
    /// Refuse it *as unanswerable*: the caller learns the run needed a human.
    case fail
}

/// Why a `fs/write_text_file` or `fs/read_text_file` was refused before it reached the
/// disk. The messages are acpx's, and reach the agent in `data.details`.
public enum FileSystemPermissionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A write refused by the permission mode, or by the user at the prompt.
    case denied
    /// Needed a confirmation, none could be asked for, and the policy is ``NonInteractivePermissionPolicy/fail``.
    case promptUnavailable
    /// A read refused by `--deny-all`.
    case readDenied

    public var description: String {
        switch self {
        case .denied: return "Permission denied for fs/write_text_file"
        case .promptUnavailable: return "Permission prompt unavailable in non-interactive mode"
        case .readDenied: return "Permission denied for fs/read_text_file (--deny-all)"
        }
    }
}

/// Whether an agent may write a file — acpx's `FileSystemHandlers.isWriteApproved`.
///
/// Writes are gated separately from tool calls: the agent never sends a
/// `session/request_permission` for a `fs/write_text_file`, so there is nothing to
/// answer — the client has to ask on its own. Upstream, and so here:
///
/// | mode | outcome |
/// |---|---|
/// | ``PermissionPolicy/approveAll`` | written |
/// | ``PermissionPolicy/denyAll`` | refused — ``FileSystemPermissionError/denied`` |
/// | anything else | asked — see ``Confirmation`` |
///
/// When asking, the default ``Confirmation`` is the terminal prompt, which answers
/// *no* when there is no terminal. With ``NonInteractivePermissionPolicy/fail`` the
/// write is refused as unanswerable instead — but only for that default prompt: an
/// embedder that supplies its own confirmation is trusted to answer headless.
///
/// ``PermissionPolicy/custom(_:)`` has no upstream counterpart; it asks, since its
/// resolver answers tool-call requests and a write carries none.
public struct WriteApproval: Sendable {
    /// Ask whether to allow writing `preview` (a shortened view of the content) to
    /// `path`. Return `false` to refuse.
    public typealias Confirmation = @Sendable (_ path: String, _ preview: String) async throws -> Bool

    public let policy: PermissionPolicy
    public let nonInteractive: NonInteractivePermissionPolicy
    private let confirm: Confirmation
    private let usesDefaultConfirmation: Bool

    private let prompt: TerminalPermissionPrompt

    /// - Parameter terminal: where the default confirmation asks — the process's own
    ///   terminal unless told otherwise. ``TerminalPermissionPrompt/none`` never asks,
    ///   which is what a daemon serving someone else's CLI wants.
    public init(
        policy: PermissionPolicy,
        nonInteractive: NonInteractivePermissionPolicy = .deny,
        confirm: Confirmation? = nil,
        terminal: TerminalPermissionPrompt = .shared
    ) {
        self.init(policy: policy, nonInteractive: nonInteractive, confirm: confirm, prompt: terminal)
    }

    init(
        policy: PermissionPolicy, nonInteractive: NonInteractivePermissionPolicy,
        confirm: Confirmation?, prompt: TerminalPermissionPrompt
    ) {
        self.policy = policy
        self.nonInteractive = nonInteractive
        self.prompt = prompt
        self.confirm = confirm ?? { path, preview in
            try await prompt.ask(
                header: "[permission] Allow write to \(path)?", details: preview,
                prompt: "Allow write? (y/N) ")
        }
        usesDefaultConfirmation = confirm == nil
    }

    /// Allow the write, or throw a ``FileSystemPermissionError``.
    public func authorize(_ request: WriteTextFileRequest) async throws {
        switch policy {
        case .approveAll:
            return
        case .denyAll:
            throw FileSystemPermissionError.denied
        case .approveReads, .custom:
            if usesDefaultConfirmation, nonInteractive == .fail, !prompt.canPrompt {
                throw FileSystemPermissionError.promptUnavailable
            }
            guard try await confirm(request.path, Self.preview(of: request.content)) else {
                throw FileSystemPermissionError.denied
            }
        }
    }

    // MARK: - Preview

    static let previewMaxLines = 16
    static let previewMaxCharacters = 1_200

    /// acpx's `toWritePreview`: the first 16 lines, a count of the rest, and at most
    /// 1,200 characters. Lengths are counted in UTF-16 code units, as JavaScript counts
    /// them, so a preview cuts where upstream's does.
    static func preview(of content: String) -> String {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        let visible = lines.prefix(previewMaxLines)
        var preview = visible.joined(separator: "\n")
        if lines.count > visible.count {
            preview += "\n... (\(lines.count - visible.count) more lines)"
        }
        let units = Array(preview.utf16)
        if units.count > previewMaxCharacters {
            preview = String(decoding: units.prefix(previewMaxCharacters - 3), as: UTF16.self) + "..."
        }
        return preview
    }
}
