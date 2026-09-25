import ACPXCore
import Foundation
import Logging
import SwiftACP

/// Cancelling a session's turn as acpx's queue owner cancels one
/// (`QueueOwnerTurnController`): once its prompt is out, the prompt is cancelled — one
/// `session/cancel` however often it is asked; before that, the cancel waits, and the
/// prompt is never sent: the turn ends cancelled. Either way the turn's prompt is not
/// sent again: an attempt that fails is not retried, and a pause before a retry ends
/// the turn cancelled at once. With no turn running there is nothing to cancel, and
/// nothing is sent.
extension ACPXDaemonBackend {
    /// A turn a session runs: starting until its prompt begins to be written, prompting
    /// from then on (acpx's `starting` and `active`).
    struct TurnControl {
        /// Which turn it is, for a late note of its prompt going out.
        let id = UUID()
        /// Where its prompt went, once it began to be written.
        var prompt: (connection: ACPAgentConnection, sessionId: SessionId)?
        /// A cancel asked before its prompt went out (acpx's `pendingCancel`).
        var cancelPending = false
        /// Whether its prompt was answered — from the moment its answer arrives, though
        /// the turn goes on — or an attempt at it failed. A cancel from then on has nothing
        /// to send, as acpx's owner finds no active prompt then, and a late note of the
        /// prompt going out is too late.
        var answered = false
        /// Whether a cancel was asked at all, its prompt out or not — acpx's aborted
        /// `waitSignal`, which its retry checks.
        var cancelAsked = false
        /// The pause before a retry, which a cancel cuts short.
        var pause: Task<Void, Never>?
        /// Whether a failed attempt at its prompt was sent again: the turn has shown the
        /// failure, so a fresh launch no longer takes it over unseen.
        var retried = false
    }

    /// Cancel the turn a session runs, as acpx's owner answers `cancelPrompt`.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    /// - Returns: whether the session runs a turn: `false` when it is idle, and then
    ///   nothing is sent.
    func cancelSession(sessionId: String) async throws -> Bool {
        guard let record = findRecord(sessionId), let turn = turns[record.acpxRecordId] else { return false }
        turns[record.acpxRecordId]?.cancelAsked = true
        if let prompt = turn.prompt {
            try await prompt.connection.cancel(sessionId: prompt.sessionId)
        } else {
            turns[record.acpxRecordId]?.cancelPending = true
            turn.pause?.cancel()
        }
        return true
    }

    /// Turn `id`'s prompt was answered: a cancel has nothing to send it from now on, as
    /// acpx's client clears its active prompt at the answer (`clearActivePrompt`) — while
    /// the turn waits for the agent's requests from it and its updates after the answer.
    func promptAnswered(recordId: String, turn id: UUID) {
        guard turns[recordId]?.id == id else { return }
        turns[recordId]?.prompt = nil
        turns[recordId]?.answered = true
    }

    /// Turn `id`'s prompt began to be written to `connection`: a cancel goes to it from
    /// now on, and one asked before is sent now (acpx's `applyPendingCancel` once the
    /// prompt is active).
    func promptWritten(recordId: String, turn id: UUID, to connection: ACPAgentConnection, sessionId: SessionId) async {
        guard turns[recordId]?.id == id, turns[recordId]?.answered == false else { return }
        turns[recordId]?.prompt = (connection, sessionId)
        guard turns[recordId]?.cancelPending == true else { return }
        turns[recordId]?.cancelPending = false
        do {
            try await connection.cancel(sessionId: sessionId)
        } catch {
            cancelLog.warning("a cancel asked before the prompt went out could not be sent: \(error)")
        }
    }
}

private let cancelLog = Logger(label: "com.cocoanetics.acpx.acpxd.cancel")
