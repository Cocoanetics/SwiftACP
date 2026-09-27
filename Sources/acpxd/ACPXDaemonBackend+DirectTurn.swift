import ACPXCore
import Foundation
import SwiftACP
import SwiftMCP

// A flow's direct turn, as acpx's `sendSessionDirect` runs one: outside the session's queue
// owner, taking only the session's turn (`acquireSessionTurn`) — no place in the owner's
// prompt line and no control ticket. So `acpx cancel` and the owner's controls do not reach
// it, and a queued prompt sent meanwhile begins in its owner and waits for the session (#225).
extension ACPXDaemonBackend {
    /// The control of turn `id` on `recordId`'s session: its owner's turn, or a direct one.
    func turnControl(_ recordId: String, _ id: UUID) -> TurnControl? {
        if let turn = turns[recordId], turn.id == id { return turn }
        return directTurns[recordId]?.first { $0.id == id }
    }

    /// The direct turn on `recordId`'s session its caller named `token`.
    func directTurn(_ recordId: String, token: String) -> TurnControl? {
        directTurns[recordId]?.first { $0.token == token }
    }

    /// Change the control of turn `id`, wherever the session keeps it.
    func changeTurn(_ recordId: String, _ id: UUID, _ change: (inout TurnControl) -> Void) {
        if var turn = turns[recordId], turn.id == id {
            change(&turn)
            turns[recordId] = turn
        } else if let index = directTurns[recordId]?.firstIndex(where: { $0.id == id }) {
            change(&directTurns[recordId]![index])
        }
    }

    /// Whether a turn of either kind runs, or waits for, `recordId`'s session.
    func hasTurn(_ recordId: String) -> Bool {
        turns[recordId] != nil || directTurns[recordId] != nil
    }

    /// Every turn on `recordId`'s session: its owner's, and the direct ones.
    func everyTurn(_ recordId: String) -> [TurnControl] {
        (turns[recordId].map { [$0] } ?? []) + (directTurns[recordId] ?? [])
    }

    /// A direct turn begins for `recordId`, kept apart from its owner's line, with its caller's
    /// `turnToken`: a cancel that named the token before now ends it as it begins
    /// (``claimTurnToken(_:for:)``). Refused while the daemon stops or the session is closed or
    /// let go, as a prompt is.
    func beginDirectTurn(_ recordId: String, turnToken: String?) throws -> TurnControl {
        guard !stopping, shuttingDown[recordId] == nil else { throw QueueOwnerShuttingDown(inLine: false) }
        var control = TurnControl()
        control.token = turnToken
        if let turnToken, calledOffTurns.removeValue(forKey: turnToken) != nil { control.cancelAsked = true }
        directTurns[recordId, default: []].append(control)
        return control
    }

    /// A direct turn is over: the session keeps it no longer, and the slot it held goes to what
    /// waits for it.
    func directTurnEnded(_ recordId: String, _ control: TurnControl, heldTheSlot: Bool) {
        directTurns[recordId]?.removeAll { $0.id == control.id }
        if directTurns[recordId]?.isEmpty == true { directTurns[recordId] = nil }
        // Called from a `defer`, which can't await.
        if heldTheSlot { Task { await turnQueue.release(recordId) } }
    }

    /// Take `recordId`'s slot for turn `id`, as acpx's turn waits for the session's
    /// (`waitForSessionTurn`): whatever holds it — a direct turn, a control — waited for within
    /// the turn's `timeout`, until a cancel of the turn cuts the wait short. It throws
    /// ``TimeoutError`` or `CancellationError` then, holding nothing.
    func takeSlot(for recordId: String, turn id: UUID, within timeout: Int?) async throws {
        let queue = turnQueue
        let wait = Task { try await queue.acquire(recordId, wait: true) }
        changeTurn(recordId, id) { $0.slotWait = wait }
        defer { changeTurn(recordId, id) { $0.slotWait = nil } }
        // A cancel asked before the wait began ends it at once.
        if turnControl(recordId, id)?.cancelAsked == true { wait.cancel() }
        do {
            // The caller gone ends the wait too.
            try await withTaskCancellationHandler {
                try await withTimeout(milliseconds: timeout) { try await wait.value }
            } onCancel: {
                wait.cancel()
            }
        } catch {
            wait.cancel()
            // Taken as the wait was given up: handed straight on.
            if (try? await wait.value) != nil { await queue.release(recordId) }
            throw error
        }
    }

    /// A turn begun, and what it began with: a queued turn's place in its owner's line and
    /// its control ticket; a direct turn has neither.
    struct StartedTurn {
        let control: TurnControl
        let begun: BegunPrompt?
        var ticket: PromptControlTicket? { begun?.ticket }
    }

    /// Begin a turn for `recordId`: a queued one in its owner's line (``beginPrompt(_:wait:turnToken:)``),
    /// which takes the slot as it begins when it may not wait; a direct one apart from it.
    func startTurn(
        _ recordId: String, direct: Bool, wait: Bool, turnToken: String?
    ) async throws -> (turn: StartedTurn, holdsTheSlot: Bool) {
        if direct {
            return (StartedTurn(control: try beginDirectTurn(recordId, turnToken: turnToken), begun: nil), false)
        }
        let begun = try await beginPrompt(recordId, wait: wait, turnToken: turnToken)
        return (StartedTurn(control: begun.control, begun: begun), !wait)
    }

    /// A turn is over, of either kind, and the slot it held — if it did — goes on.
    func turnOver(_ recordId: String, _ turn: StartedTurn, heldTheSlot: Bool) {
        if let begun = turn.begun {
            promptEnded(recordId, begun, heldTheSlot: heldTheSlot)
        } else {
            directTurnEnded(recordId, turn.control, heldTheSlot: heldTheSlot)
        }
    }

    /// A turn that ends cancelled with nothing sent — cancelled as it waited for the session, or
    /// as it took it — told to its caller as acpx's ends, nothing kept of it.
    static func endedCancelled(as sessionId: String) async -> String {
        await announceTheEnd(
            of: PromptResponse(stopReason: .cancelled), permissions: PermissionStats(),
            result: PromptResultCapture(), as: sessionId, to: Session.current)
        return ""
    }

    /// Cancel `turn` — its owner's turn or a direct one — as acpx cancels a prompt: once it is
    /// out, the agent is asked to cancel it; before, it never goes out, and a wait for the
    /// session or before a retry ends at once.
    func cancel(_ turn: TurnControl, of recordId: String) async throws {
        changeTurn(recordId, turn.id) { $0.cancelAsked = true }
        if let prompt = turn.prompt {
            try await prompt.connection.cancel(sessionId: prompt.sessionId)
        } else {
            changeTurn(recordId, turn.id) { $0.cancelPending = true }
            turn.pause?.cancel()
            turn.slotWait?.cancel()
        }
    }
}
