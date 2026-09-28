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
        /// How many may wait, until the session has an owner of its own: the depth of the
        /// prompt the line began with, which starts that owner (#240).
        var maxQueueDepth = DEFAULT_QUEUE_MAX_DEPTH
    }

    /// What a prompt begins with: its turn, which a cancel is for, and the ticket its
    /// controls go on — both the session's from the moment it begins.
    struct BegunPrompt {
        let control: TurnControl
        let ticket: PromptControlTicket
    }

    /// Begin a prompt for `recordId`: at once when no other prompt of the session has
    /// begun, else once those before it are over (``promptEnded(_:_:heldTheSlot:)``). Taken
    /// either way, it tells a caller that queued it without waiting (``NoWaitAdmission``), as
    /// acpx's owner answers `accepted` once it enqueued a task. A daemon that is
    /// stopping takes none, nor does a session being closed or let go, as acpx's owner takes
    /// no task once it shuts down (`enqueue`). The turn takes the caller's `turnToken` as it
    /// begins (``claimTurnToken(_:for:)``), and a call-off of it is kept while the prompt waits
    /// in line, however long — until the token is taken (#219 review). A prompt that would wait
    /// behind as many as the owner's depth allows is refused (``QueueOwnerOverloaded``), as acpx's
    /// owner refuses one past its `maxQueueDepth` (#240).
    func beginPrompt(
        _ recordId: String, turnToken: String? = nil, queueMaxDepth: Int? = nil
    ) async throws -> BegunPrompt {
        guard !stopping, shuttingDown[recordId] == nil else { throw QueueOwnerShuttingDown(inLine: false) }
        func begins(_ begun: BegunPrompt) -> BegunPrompt {
            if let turnToken { claimTurnToken(turnToken, for: recordId) }
            return begun
        }
        guard let line = promptLines[recordId] else {
            promptLines[recordId] = PromptLine(maxQueueDepth: Self.queueDepth(queueMaxDepth))
            Self.noWaitAdmission?.admit()
            return begins(promptBegins(recordId))
        }
        let depth = owners[recordId]?.maxQueueDepth ?? line.maxQueueDepth
        guard line.waiting.count < depth else { throw QueueOwnerOverloaded(queued: line.waiting.count, depth: depth) }
        let token = nextPromptToken
        nextPromptToken += 1
        // Waiting in line, the turn's call-off is kept however long it waits (#219 review).
        if let turnToken { waitingTurnTokens.insert(turnToken) }
        defer { if let turnToken { waitingTurnTokens.remove(turnToken) } }
        let begun = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                promptLines[recordId]?.waiting.append((token, continuation))
                Self.noWaitAdmission?.admit()
                promptWaits?(recordId)
            }
        } onCancel: {
            // onCancel is synchronous — a Task is the only way onto the actor. A prompt
            // begun before the drop lands keeps what it began with, and ends below.
            Task { await self.dropWaitingPrompt(recordId, token: token) }
        }
        // Begun, it takes its token while a call-off of it is still kept.
        _ = begins(begun)
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

    /// The session shuts down, as acpx's owner does (`beginShutdown`) — from now until `body`
    /// is over: no prompt begins meanwhile, and those still in line are refused, none of them
    /// sent.
    func whileShuttingDown<T>(_ recordId: String, _ body: () async throws -> T) async rethrows -> T {
        shuttingDown[recordId, default: 0] += 1
        defer {
            let left = (shuttingDown[recordId] ?? 1) - 1
            shuttingDown[recordId] = left > 0 ? left : nil
        }
        refusePromptsWaiting(recordId)
        return try await body()
    }

    /// The prompts still in line are refused, none of them sent.
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
/// A prompt refused because as many as the owner's depth allows wait already, in acpx's
/// words (`enqueue`, `QUEUE_OWNER_OVERLOADED`).
struct QueueOwnerOverloaded: LocalizedError, OutputErrorMeta, Equatable {
    let queued: Int
    let depth: Int
    var errorDescription: String? { "Queue owner is overloaded (\(queued)/\(depth) queued)" }
    var outputCode: String? { "RUNTIME" }
    var detailCode: String? { "QUEUE_OWNER_OVERLOADED" }
    var origin: String? { "queue" }
    var retryable: Bool? { true }
}

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
