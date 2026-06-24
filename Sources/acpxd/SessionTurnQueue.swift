import Foundation

/// Serializes prompt turns per session: at most one turn runs for a given session
/// id at a time, so concurrent CLI/MCP callers never drive one agent — or persist
/// one record — at the same moment. A turn for a session that's already running one
/// queues FIFO (or, when `wait` is false, is rejected with
/// ``DaemonError/sessionBusy``). Different sessions run concurrently.
actor SessionTurnQueue {
    /// Session ids with a turn currently running.
    private var running: Set<String> = []

    /// FIFO queues of turns waiting their slot, keyed by session id. Each waiter
    /// carries a token so a cancelled one can be dropped without disturbing the rest.
    private var waiters: [String: [(token: Int, continuation: CheckedContinuation<Bool, Never>)]] = [:]

    /// Monotonic source of waiter tokens.
    private var nextToken = 0

    /// Take the slot for `sessionId`, returning once this caller owns it. Queues
    /// behind any in-flight turn; when `wait` is false, throws
    /// ``DaemonError/sessionBusy`` instead of queueing. Pair every successful call
    /// with exactly one ``release(_:)``.
    func acquire(_ sessionId: String, wait: Bool) async throws {
        if running.insert(sessionId).inserted { return }
        guard wait else { throw DaemonError.sessionBusy(sessionId) }
        let token = nextToken
        nextToken += 1
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[sessionId, default: []].append((token, continuation))
            }
        } onCancel: {
            Task { await self.drop(sessionId, token: token) }
        }
        // `release` hands ownership over directly (the session stays marked running);
        // a `false` result means we were cancelled before reaching the front.
        if !acquired { throw CancellationError() }
    }

    /// Release the slot for `sessionId`, handing it straight to the next queued
    /// waiter (if any) so ownership passes without a gap another caller could win.
    func release(_ sessionId: String) {
        guard var queue = waiters[sessionId], !queue.isEmpty else {
            running.remove(sessionId)
            return
        }
        let next = queue.removeFirst()
        waiters[sessionId] = queue.isEmpty ? nil : queue
        next.continuation.resume(returning: true)
    }

    /// Drop a queued waiter cancelled before it got the slot, resuming it with
    /// `false` so its ``acquire(_:wait:)`` throws `CancellationError`.
    private func drop(_ sessionId: String, token: Int) {
        guard var queue = waiters[sessionId],
            let index = queue.firstIndex(where: { $0.token == token }) else { return }
        let waiter = queue.remove(at: index)
        waiters[sessionId] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(returning: false)
    }
}
