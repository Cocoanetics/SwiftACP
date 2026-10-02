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
        /// Whether a new session took its session's place before it had the slot: it is refused
        /// then, as the prompts still in line were (``holdAsNew``).
        var refused = false
        /// Whether it has the session's slot: what it connects or runs on is its own from then on.
        var running = false
        /// Its wait for the session's slot, once begun, which a cancel cuts short: it then ends
        /// cancelled, nothing sent, as acpx's queued prompt ends once its owner's cancel aborts
        /// its wait for the session's turn (`waitForSessionTurn`, #225).
        var slotWait: Task<Void, Error>?
    }

    /// Cancel the turn a session runs, as acpx's owner answers `cancelPrompt`.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    /// - Returns: whether the session runs a turn: `false` when it is idle, and then
    ///   nothing is sent.
    ///
    /// Without a `turnToken` it reaches the session's queue owner alone, as acpx's cancel
    /// does: the owner's turn, waiting for the session or running — never a flow's direct turn,
    /// which runs out of its reach (#225). Given the token its caller gave a turn — a flow's
    /// direct turn — only that turn is cancelled; one that has not begun yet is called off: it
    /// ends as it begins, nothing sent — as acpx's flow runner closes the client a stopped
    /// direct turn would prompt on (#219 review).
    func cancelSession(sessionId: String, turnToken: String? = nil) async throws -> Bool {
        guard let record = try resolveRecordIfAny(sessionId) else { return false }
        let recordId = record.acpxRecordId
        if let turnToken {
            let owners = turns[recordId].flatMap { $0.token == turnToken ? $0 : nil }
            guard let turn = directTurn(recordId, token: turnToken) ?? owners else {
                callOff(turnToken)
                return false
            }
            try await cancel(turn, of: recordId)
            return true
        }
        guard let turn = turns[recordId] else { return false }
        try await cancel(turn, of: recordId)
        return true
    }

    /// ``cancelSession(sessionId:turnToken:)``, saying whether the session's owner took the
    /// cancel — as it is taken: whether an owner holds the session is read in the same step
    /// the cancel begins in, and names this daemon, whose owner took it (#237 review).
    func cancelSessionReportingOwner(sessionId: String, turnToken: String?) async throws -> SessionCancelResult {
        let owned = turnToken == nil && findRecord(sessionId).map { owners[$0.acpxRecordId] != nil } == true
        let cancelled = try await cancelSession(sessionId: sessionId, turnToken: turnToken)
        return SessionCancelResult(cancelled: cancelled, ownerPid: Self.pid(ifOwned: owned))
    }

    /// This daemon's pid when its owner of a session took a request, as acpx's CLI names the
    /// owner that took one (#232).
    static func pid(ifOwned owned: Bool) -> Int? {
        owned ? Int(ProcessInfo.processInfo.processIdentifier) : nil
    }

    /// Cancel what runs on `recordId`'s session, its owner's turn and a direct one alike: a
    /// close or a let-go ends the session under both. Every turn is marked cancelled before the
    /// first cancel goes out: sending one suspends, and a turn waiting for the session could take
    /// it meanwhile and send its prompt, which a cancel working from what it found before would
    /// then leave running (#229 review).
    func cancelEveryTurn(_ recordId: String) async {
        let prompts = everyTurn(recordId).compactMap { markCancelled($0.id, of: recordId) }
        for prompt in prompts {
            try? await prompt.connection.cancel(sessionId: prompt.sessionId)
            await cancelSent?(recordId)
        }
    }

    /// Keep `token` as a turn's a cancel named before it began; tokens kept a minute
    /// without their turn coming are let go — unless their turn waits to begin behind
    /// another, however long that takes (#219 review).
    func callOff(_ token: String, now: Date = Date()) {
        calledOffTurns = calledOffTurns.filter {
            waitingTurnTokens.contains($0.key) || now.timeIntervalSince($0.value) < 60
        }
        calledOffTurns[token] = now
    }

    /// The turn that just began for `recordId` takes its caller's `token` (as it begins, in
    /// ``beginPrompt(_:turnToken:queueMaxDepth:)``): called off before it began, it ends at once,
    /// nothing sent, as a turn cancelled while it waited does. On the actor with no
    /// suspension, so a cancel either finds the turn by its token or leaves the token for it.
    func claimTurnToken(_ token: String, for recordId: String) {
        turns[recordId]?.token = token
        if calledOffTurns.removeValue(forKey: token) != nil { turns[recordId]?.cancelAsked = true }
    }

    /// Turn `id`'s attempt begins: until its prompt goes out, a cancel waits for it
    /// (``promptWritten(recordId:turn:to:sessionId:note:)``).
    func promptUnsent(recordId: String, turn id: UUID) {
        changeTurn(recordId, id) {
            $0.prompt = nil
            $0.answered = false
        }
    }

    /// Turn `id`'s prompt was answered: a cancel has nothing to send it from now on, as
    /// acpx's client clears its active prompt at the answer (`clearActivePrompt`) — while
    /// the turn waits for the agent's requests from it and its updates after the answer.
    func promptAnswered(recordId: String, turn id: UUID) {
        changeTurn(recordId, id) {
            $0.prompt = nil
            $0.answered = true
        }
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
        // owner publishes them (`onPromptActive`) — a queued turn's: a direct one has no ticket.
        if turns[recordId]?.id == id { tickets[recordId]?.publish() }
        guard let turn = turnControl(recordId, id), !turn.answered else { return }
        changeTurn(recordId, id) { $0.prompt = (connection, sessionId) }
        guard turn.cancelPending else { return }
        changeTurn(recordId, id) { $0.cancelPending = false }
        do {
            try await connection.cancel(sessionId: sessionId)
        } catch {
            cancelLog.warning("a cancel asked before the prompt went out could not be sent: \(error)")
        }
    }
}

private let cancelLog = Logger(label: "com.cocoanetics.acpx.acpxd.cancel")
