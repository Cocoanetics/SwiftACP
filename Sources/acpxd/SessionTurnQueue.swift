import Foundation

/// Serializes prompt turns per session: at most one turn runs for a given session
/// id at a time, so concurrent CLI/MCP callers never drive one agent — or persist
/// one record — at the same moment. A turn for a session that's already running one
/// queues FIFO (or, when `wait` is false, is rejected with
/// ``DaemonError/sessionBusy``). Different sessions run concurrently.
///
/// Prompts also queue among themselves before that, as acpx's queue owner takes one
/// prompt task at a time (`nextTask`): a prompt begins once those before it are over
/// (``beginPrompt(_:wait:)``), and only then waits for the slot — behind what took it
/// meanwhile, as acpx's owner waits for its idle controls (`priorIdle`).
actor SessionTurnQueue {
    /// What a caller waits for: the session's slot, or — a prompt — to begin.
    private enum Line {
        case slot, prompt
    }

    /// Session ids with a turn currently running.
    private var running: Set<String> = []

    /// Session ids with a prompt begun and not yet over.
    private var prompting: Set<String> = []

    /// FIFO queues of callers waiting, keyed by what they wait for and session id. Each
    /// waiter carries a token so a cancelled one can be dropped without disturbing the rest.
    private var waiters: [Line: [String: [(token: Int, continuation: CheckedContinuation<Bool, Never>)]]] = [:]

    /// Monotonic source of waiter tokens.
    private var nextToken = 0

    /// Told the session id whenever a turn queues behind another — so a test can
    /// wait until a caller is waiting.
    private var onQueued: (@Sendable (String) -> Void)?

    func setOnQueued(_ observer: (@Sendable (String) -> Void)?) {
        onQueued = observer
    }

    /// Take the slot for `sessionId`, returning once this caller owns it. Queues
    /// behind any in-flight turn; when `wait` is false, throws
    /// ``DaemonError/sessionBusy`` instead of queueing. Pair every successful call
    /// with exactly one ``release(_:)``.
    func acquire(_ sessionId: String, wait: Bool) async throws {
        if running.insert(sessionId).inserted { return }
        guard wait else { throw DaemonError.sessionBusy(sessionId) }
        // `release` hands ownership over directly (the session stays marked running);
        // a `false` result means we were cancelled before reaching the front.
        guard await queue(for: .slot, sessionId) else { throw CancellationError() }
    }

    /// Begin a prompt for `sessionId`, as acpx's queue owner takes a prompt task: at once
    /// when no other prompt of the session has begun, else once those before it are over.
    /// Pair every successful call with exactly one ``endPrompt(_:)``.
    ///
    /// When `wait` is false, the prompt takes the slot as it begins, or throws
    /// ``DaemonError/sessionBusy`` when anything holds either — pair it with a
    /// ``release(_:)`` too.
    func beginPrompt(_ sessionId: String, wait: Bool) async throws {
        guard wait else {
            guard !prompting.contains(sessionId), !running.contains(sessionId) else {
                throw DaemonError.sessionBusy(sessionId)
            }
            prompting.insert(sessionId)
            running.insert(sessionId)
            return
        }
        if prompting.insert(sessionId).inserted { return }
        guard await queue(for: .prompt, sessionId) else { throw CancellationError() }
    }

    /// Whether a turn or control holds the slot for `sessionId`.
    func isBusy(_ sessionId: String) -> Bool {
        running.contains(sessionId)
    }

    /// Release the slot for `sessionId`, handing it straight to the next queued
    /// waiter (if any) so ownership passes without a gap another caller could win.
    func release(_ sessionId: String) {
        if !handOn(.slot, sessionId) { running.remove(sessionId) }
    }

    /// The prompt begun for `sessionId` is over: the next waiting to begin does, as acpx's
    /// owner takes its next task.
    func endPrompt(_ sessionId: String) {
        if !handOn(.prompt, sessionId) { prompting.remove(sessionId) }
    }

    /// Wait in `line` for `sessionId`, FIFO: `true` once handed what it waits for, `false`
    /// when cancelled first.
    private func queue(for line: Line, _ sessionId: String) async -> Bool {
        let token = nextToken
        nextToken += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[line, default: [:]][sessionId, default: []].append((token, continuation))
                onQueued?(sessionId)
            }
        } onCancel: {
            // onCancel is synchronous — a Task is the only way onto the actor. If the
            // wait is handed on before drop() lands, drop() finds no matching token and
            // is a no-op; the caller keeps what it was handed.
            Task { await self.drop(line, sessionId, token: token) }
        }
    }

    /// Hand what `line` waits for straight to its next waiter for `sessionId`, returning
    /// whether there was one (it stays marked held).
    private func handOn(_ line: Line, _ sessionId: String) -> Bool {
        guard var queue = waiters[line]?[sessionId], !queue.isEmpty else { return false }
        let next = queue.removeFirst()
        waiters[line]?[sessionId] = queue.isEmpty ? nil : queue
        next.continuation.resume(returning: true)
        return true
    }

    /// Drop a queued waiter cancelled before it reached the front, resuming it with
    /// `false` so its wait throws `CancellationError`.
    private func drop(_ line: Line, _ sessionId: String, token: Int) {
        guard var queue = waiters[line]?[sessionId],
            let index = queue.firstIndex(where: { $0.token == token }) else { return }
        let waiter = queue.remove(at: index)
        waiters[line]?[sessionId] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(returning: false)
    }
}
