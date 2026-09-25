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
    /// cancelled. The rest of the terminal requests are served as they come.
    ///
    /// Those read with no prompt in flight are served as they come too, but not for a
    /// session being closed: acpx asks of each, owned by a prompt or not, that its session
    /// is not being cancelled or closed (`assertActive`), and a close ends those still
    /// being served (`abortSessionRequests`, ``answerSessionRequestsCancelled(_:)``).
    func servingUnlessCancelled(
        _ method: String, _ params: JSONValue?, sessionId: SessionId?
    ) async -> Result<JSONValue, JSONRPCErrorBody> {
        guard RequestOwnership.ownedMethods.contains(method) else {
            return await handleIncomingRequest(method: method, params: params)
        }
        let owner = requestOwnership.claim(method, params)
        guard let sessionId else { return await handleIncomingRequest(method: method, params: params) }
        if cancellingSessionIds.contains(sessionId) || owner.map(requestOwnership.isAnswered) == true {
            return Self.cancelledAnswer(to: method)
        }
        if owner != nil { await afterClaimingOwnedRequest?() }
        let key = UUID()
        let result = await withCheckedContinuation { continuation in
            let request = TurnRequest(method: method, continuation: continuation)
            if owner != nil {
                turnRequests[sessionId, default: [:]][key] = request
            } else {
                unownedRequests[sessionId, default: [:]][key] = request
            }
            let serving = Task {
                // Its prompt was answered as it was taken up — `track` stopped it before it
                // started: answered cancelled without being served, and not counted, as acpx
                // answers a request whose owner is no longer active.
                guard !Task.isCancelled else {
                    request.answer(Self.cancelledAnswer(to: method))
                    return
                }
                let tally = PermissionTally()
                let answer = await PermissionTally.$current.withValue(tally) {
                    await self.handleIncomingRequest(method: method, params: params)
                }
                if owner != nil { await self.afterServingOwnedRequest?() }
                // Its prompt ended while this was served — its answer read, or its turn
                // cancelled — or its session was closed: acpx answers it cancelled then, and
                // counts a question so. What it counts, it counts by the answer that goes back.
                guard Task.isCancelled else {
                    // What the handler reports of its decision goes out with it, ahead of
                    // anything the agent sends in reaction.
                    for operation in tally.announced { self.publish(.clientOperation(operation)) }
                    if request.answer(answer), let noted = tally.noted { self.count(noted, in: sessionId) }
                    return
                }
                if request.answer(Self.cancelledAnswer(to: method)), method == "session/request_permission" {
                    self.turnPermissionStats[sessionId, default: PermissionStats()].record(.cancelled)
                }
            }
            request.serving = serving
            // The prompt's answer, once read, stops it at once — ahead of the prompt's call
            // resuming — as acpx's `clearActivePrompt` aborts its owner.
            if let owner { requestOwnership.track(serving, as: key, ownedBy: owner) }
        }
        if let owner { requestOwnership.untrack(key, ownedBy: owner) }
        turnRequests[sessionId]?[key] = nil
        unownedRequests[sessionId]?[key] = nil
        return result
    }

    /// Whether any request of this client's waits for its answer — one that closing the
    /// connection fails.
    public var hasRequestsOutstanding: Bool {
        requestsOutstanding > 0
    }

    /// Whether `sessionId` has a prompt out, not answered yet — acpx's active prompt,
    /// which an interrupt cancels (`cancelActivePrompt`).
    public func hasPromptInFlight(sessionId: SessionId) -> Bool {
        promptingSessionIds.contains(sessionId)
    }

    /// Return once `sessionId` has no prompt out — at once when it has none, else when its
    /// prompt settles — saying whether its latest prompt was answered, rather than failed;
    /// `nil` when it has sent none.
    public func waitForPromptToSettle(sessionId: SessionId) async -> Bool? {
        guard promptingSessionIds.contains(sessionId) else { return latestPromptAnswered[sessionId] }
        return await withCheckedContinuation { promptSettledWaiters[sessionId, default: []].append($0) }
    }

    /// End what `sessionId`'s prompt in flight owns, and leave the prompt out — as acpx
    /// aborts the requests of a prompt that ran past its deadline (`abortTimedOutRequests`)
    /// while it waits to see whether an answer comes: an owned request still open is
    /// answered cancelled, and so is one read later, until the prompt ends. No
    /// `session/cancel` goes out.
    public func abandonTurnRequests(sessionId: SessionId) {
        guard promptingSessionIds.contains(sessionId) else { return }
        cancellingSessionIds.insert(sessionId)
        answerTurnRequestsCancelled(sessionId)
    }

    /// Answer `sessionId`'s owned requests still being served as cancelled, and stop
    /// serving them.
    func answerTurnRequestsCancelled(_ sessionId: SessionId) {
        answerCancelled(turnRequests.removeValue(forKey: sessionId), in: sessionId)
    }

    /// Answer every request of `sessionId`'s still being served as cancelled, those read
    /// with no prompt in flight too, and stop serving them: acpx ends them all at a close
    /// (`abortSessionRequests`).
    func answerSessionRequestsCancelled(_ sessionId: SessionId) {
        answerTurnRequestsCancelled(sessionId)
        answerCancelled(unownedRequests.removeValue(forKey: sessionId), in: sessionId)
    }

    private func answerCancelled(_ requests: [UUID: TurnRequest]?, in sessionId: SessionId) {
        for request in (requests ?? [:]).values {
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

extension ACPAgentConnection {
    /// Count `noted` in `sessionId`'s turn, or — while a request is served for its
    /// prompt — keep it for when that request's answer goes back (``PermissionTally``).
    func note(_ noted: PermissionTally.Note, in sessionId: SessionId) {
        if let tally = PermissionTally.current {
            tally.note(noted)
        } else {
            count(noted, in: sessionId)
        }
    }

    fileprivate func count(_ noted: PermissionTally.Note, in sessionId: SessionId) {
        turnPermissionStats[sessionId, default: PermissionStats()].record(noted.decision)
        if noted.promptUnavailable { turnPermissionStats[sessionId]?.promptUnavailable = true }
    }
}

/// What a request served for its prompt came to — in the permission stats, a question's
/// decision or a refusal; on the event stream, the notices explaining a decision — kept
/// until its answer goes back, and dropped if that answer is not the one that does. When
/// the prompt ends first, a question is answered `cancelled` and counts as that, and a
/// refusal is answered `Request cancelled` and does not count: acpx counts and reports
/// what it answers, while the request's owner is active (`finishPermissionRequest`,
/// `runDelegatedOperation`, `assertControlAuthority` ahead of its notices).
final class PermissionTally: @unchecked Sendable {
    struct Note {
        var decision: PermissionStats.Decision
        /// A write or command needed a confirmation nobody could give.
        var promptUnavailable = false
    }

    /// The tally of the request being served, when it is served for its prompt.
    @TaskLocal static var current: PermissionTally?

    private let lock = NSLock()
    private var kept: Note?
    private var notices: [ClientOperation] = []

    func note(_ note: Note) {
        lock.withLock { kept = note }
    }

    var noted: Note? { lock.withLock { kept } }

    func announce(_ operation: ClientOperation) {
        lock.withLock { notices.append(operation) }
    }

    var announced: [ClientOperation] { lock.withLock { notices } }
}

/// An agent's request being served, and the one answer it gets: its handler's, or its
/// turn's cancel's or its session's close's, whichever comes first.
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
