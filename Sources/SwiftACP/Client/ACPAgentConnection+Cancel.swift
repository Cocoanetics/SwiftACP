import Foundation
import JSONFoundation

// Cancelling a turn as acpx's client does (`AcpClient.cancel`): one `session/cancel` for
// the prompt in flight, however often it is asked, and the agent's requests of the turn
// answered as cancelled from then on.
//
// Split from `ACPAgentConnection.swift` to keep that file inside the 500-line limit.
extension ACPAgentConnection {
    /// Cancel `sessionId`'s turn. For a prompt in flight `session/cancel` goes out once:
    /// a later cancel waits on that same send, and one after a send that failed tries
    /// again (acpx's `cancelPromise`). The agent's requests of the turn are answered as
    /// cancelled from then on (``servingUnlessCancelled(_:_:sessionId:)``). With no
    /// prompt in flight the notification just goes out.
    public func cancel(sessionId: SessionId) async throws {
        guard promptingSessionIds.contains(sessionId) else {
            try await sendCancel(sessionId)
            return
        }
        cancellingSessionIds.insert(sessionId)
        answerTurnRequestsCancelled(sessionId)
        let send = cancelSends[sessionId] ?? Task { try await self.sendCancel(sessionId) }
        cancelSends[sessionId] = send
        do {
            try await send.value
        } catch {
            if cancelSends[sessionId] == send { cancelSends[sessionId] = nil }
            throw error
        }
    }

    private func sendCancel(_ sessionId: SessionId) async throws {
        let params = try JSONValue(encoding: CancelNotification(sessionId: sessionId))
        try await rpc.sendNotification(method: "session/cancel", params: params)
    }

    /// Serve an agent's request, unless the prompt it belongs to is over: acpx binds a
    /// permission question, a file request and starting a command to the prompt in
    /// flight when it was read (``RequestOwnership``), and ends them with it — at its
    /// answer, and at a cancel. One whose prompt was answered or cancelled before it is
    /// served is answered so without being served, and not counted. One still being
    /// served when that comes is answered so at once — a permission question then counts
    /// as cancelled, as `finishPermissionRequest` counts it — and what serves it is
    /// cancelled. The rest of the terminal requests, and those read with no prompt in
    /// flight, are served as they come.
    func servingUnlessCancelled(
        _ method: String, _ params: JSONValue?, sessionId: SessionId?
    ) async -> Result<JSONValue, JSONRPCErrorBody> {
        guard RequestOwnership.ownedMethods.contains(method) else {
            return await handleIncomingRequest(method: method, params: params)
        }
        guard let owner = requestOwnership.claim(method, params), let sessionId else {
            return await handleIncomingRequest(method: method, params: params)
        }
        if requestOwnership.isAnswered(owner) || cancellingSessionIds.contains(sessionId) {
            return Self.cancelledAnswer(to: method)
        }
        let key = UUID()
        let result = await withCheckedContinuation { continuation in
            let request = TurnRequest(method: method, continuation: continuation)
            turnRequests[sessionId, default: [:]][key] = request
            let serving = Task {
                let answer = await self.handleIncomingRequest(method: method, params: params)
                // Its prompt ended while this was served — its answer read, or its turn
                // cancelled: acpx answers it cancelled then, and counts a question so.
                guard Task.isCancelled else {
                    request.answer(answer)
                    return
                }
                if request.answer(Self.cancelledAnswer(to: method)), method == "session/request_permission" {
                    self.turnPermissionStats[sessionId, default: PermissionStats()].record(.cancelled)
                }
            }
            request.serving = serving
            // The prompt's answer, once read, stops it at once — ahead of the prompt's call
            // resuming — as acpx's `clearActivePrompt` aborts its owner.
            requestOwnership.track(serving, ownedBy: owner)
        }
        requestOwnership.untrack(owner)
        turnRequests[sessionId]?[key] = nil
        return result
    }

    /// Answer `sessionId`'s owned requests still being served as cancelled, and stop
    /// serving them.
    func answerTurnRequestsCancelled(_ sessionId: SessionId) {
        for request in (turnRequests.removeValue(forKey: sessionId) ?? [:]).values {
            let answered = request.answer(Self.cancelledAnswer(to: request.method))
            if answered, request.method == "session/request_permission" {
                turnPermissionStats[sessionId, default: PermissionStats()].record(.cancelled)
            }
            request.serving?.cancel()
        }
    }

    /// How acpx answers a request of a turn it cancelled: a permission question
    /// `cancelled`, anything else `Request cancelled`.
    static func cancelledAnswer(to method: String) -> Result<JSONValue, JSONRPCErrorBody> {
        guard method == "session/request_permission",
            let cancelled = try? JSONValue(encoding: RequestPermissionResponse(outcome: .cancelled))
        else { return .failure(requestCancelled) }
        return .success(cancelled)
    }
}

/// An agent's request of a turn in flight, and the one answer it gets: its handler's,
/// or its turn's cancel's, whichever comes first.
final class TurnRequest: @unchecked Sendable {
    let method: String
    /// What serves it, cancelled when the turn is. Set on the connection's actor.
    var serving: Task<Void, Never>?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<JSONValue, JSONRPCErrorBody>, Never>?

    init(method: String, continuation: CheckedContinuation<Result<JSONValue, JSONRPCErrorBody>, Never>) {
        self.method = method
        self.continuation = continuation
    }

    /// Give `result` as the request's answer, unless it already has one. Returns
    /// whether it is the answer.
    @discardableResult
    func answer(_ result: Result<JSONValue, JSONRPCErrorBody>) -> Bool {
        let pending: CheckedContinuation<Result<JSONValue, JSONRPCErrorBody>, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: result)
        return pending != nil
    }
}
