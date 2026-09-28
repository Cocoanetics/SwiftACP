import Foundation
import SwiftACP

/// One turn's permissions, as acpx sends them with every prompt: the mode
/// (`--approve-all` / `--approve-reads` / `--deny-all`) and what a write needing
/// confirmation does without a terminal. The daemon swaps the live agent's handlers
/// to these for the turn — acpx's queue owner applies each prompt's mode to that turn.
struct TurnPermissions: Sendable {
    let handlers: ACPClientHandlers

    /// - Parameters:
    ///   - mode: `approve-all`, `approve-reads` or `deny-all`. `nil` — a caller that
    ///     predates the parameter — keeps the old behaviour of approving everything.
    ///   - nonInteractive: `deny` (the default) or `fail`.
    ///   - rules: the turn's per-tool permission policy, which comes before `mode`.
    init(mode: String?, nonInteractive: String?, rules: PermissionRules? = nil) throws {
        let policy: PermissionPolicy
        if let mode {
            guard let parsed = PermissionPolicy(acpxMode: mode) else {
                throw DaemonError.invalidPermissionMode(mode)
            }
            policy = parsed
        } else {
            policy = .approveAll
        }
        let unanswerable: NonInteractivePermissionPolicy
        if let nonInteractive {
            guard let parsed = NonInteractivePermissionPolicy(rawValue: nonInteractive) else {
                throw DaemonError.invalidNonInteractivePermissions(nonInteractive)
            }
            unanswerable = parsed
        } else {
            unanswerable = .deny
        }
        // `.none`: the daemon's own terminal, if it has one, is not the user's. Like
        // acpx's detached queue owner, it never asks — a write needing confirmation is
        // refused, or refused as unanswerable under `fail`.
        handlers = .standard(
            permission: policy, nonInteractivePermissions: unanswerable, terminal: .none, rules: rules)
    }
}
