import ACPXCore
import Foundation
import Logging
import SwiftACP

/// Cancelling a session's turn as acpx's queue owner cancels one
/// (`QueueOwnerTurnController`): once its prompt is out, the prompt is cancelled — one
/// `session/cancel` however often it is asked; before that, the cancel waits, and the
/// prompt is never sent: the turn ends cancelled. Either way the turn's prompt is not
/// sent again: an attempt that fails is not retried, and a pause before a retry ends
/// the turn cancelled at once. A prompt begun but still waiting for the session ends
/// cancelled once it holds it, nothing kept of it. With no turn running there is nothing
/// to cancel, and nothing is sent.
extension ACPXDaemonBackend {
    /// A turn a session runs, from when its prompt begins: starting until the prompt begins
    /// to be written — waiting for the session first — and prompting from then on (acpx's
    /// `starting` and `active`).
    struct TurnControl {
        /// Which turn it is, for a late note of its prompt going out.
        let id = UUID()
        /// The caller's name for it, which a cancel can give (a flow's direct turn).
        var token: String?
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
    ///
    /// Given the `turnToken` its caller gave a turn, only that turn is cancelled. One that
    /// has not begun yet is called off: it ends as it begins, nothing sent — as acpx's flow
    /// runner closes the client a stopped direct turn would prompt on (#219 review).
    func cancelSession(sessionId: String, turnToken: String? = nil) async throws -> Bool {
        guard let record = findRecord(sessionId) else { return false }
        guard let turn = turns[record.acpxRecordId], turnToken == nil || turn.token == turnToken else {
            if let turnToken { callOff(turnToken) }
            return false
        }
        turns[record.acpxRecordId]?.cancelAsked = true
        if let prompt = turn.prompt {
            try await prompt.connection.cancel(sessionId: prompt.sessionId)
        } else {
            turns[record.acpxRecordId]?.cancelPending = true
            turn.pause?.cancel()
        }
        return true
    }

    /// Keep `token` as a turn's a cancel named before it began; tokens kept a minute
    /// without their turn coming are let go.
    private func callOff(_ token: String) {
        let now = Date()
        calledOffTurns = calledOffTurns.filter { now.timeIntervalSince($0.value) < 60 }
        calledOffTurns[token] = now
    }

    /// The turn that just began for `recordId` takes its caller's `token`: called off
    /// before it began, it ends at once, nothing sent, as a turn cancelled while it waited
    /// does. On the actor with no suspension, so a cancel either finds the turn by its
    /// token or leaves the token for it.
    func claimTurnToken(_ token: String, for recordId: String) {
        turns[recordId]?.token = token
        if calledOffTurns.removeValue(forKey: token) != nil { turns[recordId]?.cancelAsked = true }
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
    /// prompt is active). A `note` the turn took already, acting on the attempt's end
    /// before it came (``takePromptNote(of:from:)``), comes too late to do anything.
    func promptWritten(
        recordId: String, turn id: UUID, to connection: ACPAgentConnection, sessionId: SessionId, note: WriteMark
    ) async {
        guard note.takeNote() else { return }
        // The prompt went out: the controls sent meanwhile run on its agent now, as acpx's
        // owner publishes them (`onPromptActive`).
        if turns[recordId]?.id == id { tickets[recordId]?.publish() }
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
