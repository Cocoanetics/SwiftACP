import ACPXCore
import Foundation

// A session's prompts begin one at a time, as acpx's queue owner takes one prompt task at
// a time (`nextTask`) and begins it (`runPromptTurn`): its turn is the session's from then
// on, and so is its control ticket, before it waits for the controls ahead of it
// (`priorIdle`). acpx's owner goes from ending one task to beginning the next with nothing
// in between, so here a prompt ends and the next begins in one step on the actor: nothing
// sent meanwhile finds the session between prompts.
extension ACPXDaemonBackend {
    /// A session's prompts waiting to begin after the one begun, in order: each resumed
    /// with what it begins with, or with why it never will.
    struct PromptLine {
        var waiting: [(token: Int, continuation: CheckedContinuation<BegunPrompt, Error>)] = []
    }

    /// What a prompt begins with: its turn, which a cancel is for, and the ticket its
    /// controls go on — both the session's from the moment it begins.
    struct BegunPrompt {
        let control: TurnControl
        let ticket: PromptControlTicket
    }

    /// Begin a prompt for `recordId`: at once when no other prompt of the session has
    /// begun, else once those before it are over (``promptEnded(_:_:heldTheSlot:)``).
    /// When `wait` is false, a session running anything refuses it with
    /// ``DaemonError/sessionBusy``, and it takes the slot as it begins. A daemon that is
    /// stopping takes none, as acpx's owner takes no task once it shuts down (`enqueue`).
    func beginPrompt(_ recordId: String, wait: Bool) async throws -> BegunPrompt {
        guard !stopping else { throw QueueOwnerShuttingDown(inLine: false) }
        guard wait else {
            try await turnQueue.acquire(recordId, wait: false)
            guard promptLines[recordId] == nil else {
                Task { await turnQueue.release(recordId) }
                throw DaemonError.sessionBusy(recordId)
            }
            promptLines[recordId] = PromptLine()
            return promptBegins(recordId)
        }
        if promptLines[recordId] == nil {
            promptLines[recordId] = PromptLine()
            return promptBegins(recordId)
        }
        let token = nextPromptToken
        nextPromptToken += 1
        let begun = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                promptLines[recordId]?.waiting.append((token, continuation))
                promptWaits?(recordId)
            }
        } onCancel: {
            // onCancel is synchronous — a Task is the only way onto the actor. A prompt
            // begun before the drop lands keeps what it began with, and ends below.
            Task { await self.dropWaitingPrompt(recordId, token: token) }
        }
        // Called off as it began: it ends at once, handing the line on, as acpx's owner
        // cancels a task it has just taken (Codex review on #196).
        if Task.isCancelled {
            promptEnded(recordId, begun, heldTheSlot: false)
            throw CancellationError()
        }
        return begun
    }

    /// A begun prompt is over, as acpx's owner ends the prompt task it took: its ticket
    /// sealed and let go — a control from now on runs between turns — and its turn no
    /// longer the session's. The next prompt waiting begins in the same step. Then the
    /// slot, if it held it, goes to what waits for it, and the owner waits for its next
    /// prompt, as acpx's owner does after any task it took, one that never held the
    /// session too.
    @discardableResult
    func promptEnded(_ recordId: String, _ begun: BegunPrompt, heldTheSlot: Bool) -> Task<Void, Never> {
        begun.ticket.seal()
        if tickets[recordId] === begun.ticket { tickets[recordId] = nil }
        if turns[recordId]?.id == begun.control.id { turns[recordId] = nil }
        if var line = promptLines[recordId], !line.waiting.isEmpty {
            let next = line.waiting.removeFirst()
            promptLines[recordId] = line
            next.continuation.resume(returning: promptBegins(recordId))
        } else {
            promptLines[recordId] = nil
        }
        // Called from a `defer`, which can't await; the hop to the queue actor is safe
        // because release hands the slot to the next FIFO waiter whenever it lands.
        return Task {
            if heldTheSlot { await turnQueue.release(recordId) }
            await self.turnEnded(recordId)
        }
    }

    /// The session's prompt begins: its turn and ticket are the session's.
    private func promptBegins(_ recordId: String) -> BegunPrompt {
        let begun = BegunPrompt(control: TurnControl(), ticket: PromptControlTicket())
        turns[recordId] = begun.control
        tickets[recordId] = begun.ticket
        return begun
    }

    /// The session's owner shuts down, as acpx's does (`beginShutdown`): the prompts still in
    /// line are refused, none of them sent.
    func refusePromptsWaiting(_ recordId: String) {
        guard let waiting = promptLines[recordId]?.waiting, !waiting.isEmpty else { return }
        promptLines[recordId]?.waiting = []
        waiting.forEach { $0.continuation.resume(throwing: QueueOwnerShuttingDown(inLine: true)) }
    }

    /// Drop a prompt called off before it began.
    private func dropWaitingPrompt(_ recordId: String, token: Int) {
        guard let index = promptLines[recordId]?.waiting.firstIndex(where: { $0.token == token }),
              let waiter = promptLines[recordId]?.waiting.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// acpx's error for a prompt its session's owner refuses as it shuts down: one still in line
/// (`beginShutdown`), or one sent once it began to (`enqueue`).
struct QueueOwnerShuttingDown: LocalizedError, OutputErrorMeta, Equatable {
    /// Whether the prompt was in line as the shutdown began.
    let inLine: Bool
    var errorDescription: String? {
        inLine ? "Queue owner shutting down before prompt execution" : "Queue owner is shutting down"
    }
    var outputCode: String? { "RUNTIME" }
    var detailCode: String? { "QUEUE_OWNER_SHUTTING_DOWN" }
    var origin: String? { "queue" }
    var retryable: Bool? { true }
}
