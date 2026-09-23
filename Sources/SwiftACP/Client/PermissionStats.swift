import Foundation

/// How the permissions asked for during one turn were settled — acpx's
/// `permissionStats`. It decides the exit code: a turn that needed permission and got
/// none exits with `PERMISSION_DENIED` (5) even when the agent itself finished normally.
///
/// Two sources feed it, as upstream:
///
/// - every `session/request_permission`, classified by the answer that went back;
/// - every `fs/write_text_file` the client *refused* (``FileSystemPermissionError``).
///   A write that was allowed is not counted — upstream records delegated operations
///   only when they fail — so one approved tool call is enough to keep a turn with a
///   refused write from exiting 5.
public struct PermissionStats: Sendable, Equatable {
    public var requested = 0
    public var approved = 0
    public var denied = 0
    public var cancelled = 0
    /// A write needed confirmation that could not be asked for, under
    /// ``NonInteractivePermissionPolicy/fail``. Upstream rethrows this once the turn
    /// returns, so it fails the run on its own — exit 5 — even if something else in
    /// the turn was approved.
    public var promptUnavailable = false

    public init() {}

    /// acpx's `applyPermissionExitCode` condition: something needed permission, nothing
    /// was granted, and something was refused or went unanswered.
    public var deniedEverything: Bool {
        requested > 0 && approved == 0 && denied + cancelled > 0
    }

    enum Decision { case approved, denied, cancelled }

    mutating func record(_ decision: Decision) {
        requested += 1
        switch decision {
        case .approved: approved += 1
        case .denied: denied += 1
        case .cancelled: cancelled += 1
        }
    }

    /// acpx's `classifyPermissionDecision`: an allow option is an approval, any other
    /// selected option a refusal, and no selection — or one naming an option the agent
    /// never offered — a cancellation.
    static func classify(
        _ request: RequestPermissionRequest, _ response: RequestPermissionResponse
    ) -> Decision {
        guard case .selected(let optionId) = response.outcome,
            let option = request.options.first(where: { $0.optionId == optionId })
        else { return .cancelled }
        return option.kind == .allowOnce || option.kind == .allowAlways ? .approved : .denied
    }
}
