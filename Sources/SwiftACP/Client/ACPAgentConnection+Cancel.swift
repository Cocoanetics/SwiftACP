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

    /// The agent's requests a turn's cancel answers — acpx's delegated requests.
    static let turnRequestMethods: Set<String> =
        terminalMethods.union(["fs/read_text_file", "fs/write_text_file", "session/request_permission"])

    /// Serve an agent's request, unless it belongs to a turn being cancelled: acpx binds
    /// it to the prompt in flight (`captureDelegatedRequestOwner`). One arriving once the
    /// turn is cancelled is answered so without being served. One still being served
    /// when the cancel comes is answered so at once — a permission question then counts
    /// as cancelled, as `finishPermissionRequest` counts it — and what serves it is
    /// cancelled.
    func servingUnlessCancelled(
        _ method: String, _ params: JSONValue?, sessionId: SessionId?
    ) async -> Result<JSONValue, JSONRPCErrorBody> {
        guard let sessionId, Self.turnRequestMethods.contains(method), promptingSessionIds.contains(sessionId)
        else { return await handleIncomingRequest(method: method, params: params) }
        if cancellingSessionIds.contains(sessionId) { return Self.cancelledAnswer(to: method) }
        let key = UUID()
        let result = await withCheckedContinuation { continuation in
            let request = TurnRequest(method: method, continuation: continuation)
            turnRequests[sessionId, default: [:]][key] = request
            request.serving = Task { request.answer(await self.handleIncomingRequest(method: method, params: params)) }
        }
        turnRequests[sessionId]?[key] = nil
        return result
    }

    private func answerTurnRequestsCancelled(_ sessionId: SessionId) {
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
