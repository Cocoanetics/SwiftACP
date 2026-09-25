import Dispatch
import Foundation
import JSONFoundation
import JSONRPCPeer

// The agent's `session/update`s: fanned out to the subscriptions — except a
// session's while its `session/load` replays history the caller already has — and
// waited on until that replay stops.
//
// Split from `ACPAgentConnection.swift` to keep that file inside the 500-line limit;
// the members this reaches are internal rather than private so both halves can.
extension ACPAgentConnection {
    /// A notification from the agent: a `session/update` goes to every subscription,
    /// unless a replay is being kept from them.
    func handleIncomingNotification(method: String, params: JSONValue?) async {
        guard method == "session/update" else { return }
        let sessionId = InboundRequestLedger.sessionId(of: params)
        defer { if let sessionId { sessionUpdates.finished(sessionId) } }
        await beforeHandlingUpdate?()
        guard let params, let notification = try? params.decoded(SessionNotification.self) else { return }
        if replaySuppressed[notification.sessionId] != nil { return }
        for sink in updateSinks.values {
            sink.yield(notification)
        }
        eventSinks.yield(.update(notification))
    }

    /// `session/load` as acpx's `loadSessionWithOptions` sends it: the request, then the
    /// replay drain. With `suppressReplayUpdates`, the session's updates meanwhile are
    /// neither delivered nor shown on `rawWire` — the caller has that history already.
    ///
    /// Loads of one session take turns, each waiting for the one before to finish its
    /// drain. Which load a replayed update belongs to can only be told by when it
    /// arrives, so an ordinary load overlapping one that suppresses would lose its own.
    ///
    /// - Parameters:
    ///   - replayIdleMilliseconds: how long the replay has to have been quiet, as acpx's
    ///     `replayIdleMs` (80).
    ///   - replayDrainTimeoutMilliseconds: how long to wait for that at most, as acpx's
    ///     `replayDrainTimeoutMs` (5000).
    public func loadSession(
        _ request: LoadSessionRequest, suppressReplayUpdates: Bool, rawWire: RawWireTap? = nil,
        replayIdleMilliseconds: Int = 80, replayDrainTimeoutMilliseconds: Int = 5000
    ) async throws -> LoadSessionResponse {
        let id = request.sessionId
        await beginLoading(id)
        defer { endLoading(id) }
        if suppressReplayUpdates {
            beginSuppressingReplay(of: id)
            rawWire?.beginSuppressingReplay(of: id)
        }
        defer {
            if suppressReplayUpdates {
                endSuppressingReplay(of: id)
                rawWire?.endSuppressingReplay(of: id)
            }
        }
        let response = try await loadSession(request)
        try await waitForSessionUpdateDrain(
            sessionId: id, idleMilliseconds: replayIdleMilliseconds,
            timeoutMilliseconds: replayDrainTimeoutMilliseconds)
        return response
    }

    /// Wait for any other load of `sessionId` to finish, then hold the session's turn
    /// until ``endLoading(_:)``.
    func beginLoading(_ sessionId: SessionId) async {
        guard loadWaiters[sessionId] != nil else {
            loadWaiters[sessionId] = []
            return
        }
        await withCheckedContinuation { continuation in
            loadWaiters[sessionId, default: []].append(continuation)
        }
    }

    /// Hand the session's turn to the next load waiting for it, or give it up.
    func endLoading(_ sessionId: SessionId) {
        guard var waiting = loadWaiters[sessionId], !waiting.isEmpty else {
            loadWaiters[sessionId] = nil
            return
        }
        let next = waiting.removeFirst()
        loadWaiters[sessionId] = waiting
        next.resume()
    }

    /// Stop delivering `sessionId`'s `session/update`s until the matching
    /// ``endSuppressingReplay(of:)``: its `session/load` replays history the caller
    /// has. Other sessions' updates go on as usual.
    func beginSuppressingReplay(of sessionId: SessionId) {
        replaySuppressed[sessionId, default: 0] += 1
    }

    func endSuppressingReplay(of sessionId: SessionId) {
        guard let count = replaySuppressed[sessionId] else { return }
        replaySuppressed[sessionId] = count > 1 ? count - 1 : nil
    }

    /// How many requests `sessionId`'s agent has made of this client so far: compared
    /// across a wait, whether one came — answered or not — meanwhile.
    public func requestsArrived(sessionId: SessionId) -> Int {
        inboundRequests.arrivalCount(sessionId)
    }

    /// Wait until every request `sessionId`'s agent has made of this client is answered —
    /// one it sends after a turn's answer, while the turn waits for its updates to go
    /// quiet, as much as one sent before. Returns whether any was still open.
    @discardableResult
    public func waitForRequestsAnswered(sessionId: SessionId) async -> Bool {
        await inboundRequests.waitUntilIdle(sessionId)
    }

    /// Hand every JSON-RPC message to `observer` as it crosses the wire, decoded, with
    /// its direction: in order, and before it is handled — a request of the agent's is
    /// announced on the event stream, and an update counted, before `observer` sees it.
    /// The closure runs synchronously, so it must be fast. Pass `nil` to stop.
    public func setWireMessageObserver(
        _ observer: (@Sendable (JSONRPCPeer.WireDirection, JSONRPCMessage) -> Void)?
    ) async {
        wireObserver.setMessages(observer)
    }

    /// Return once every `session/update` for `sessionId` the connection has read has
    /// been handled — handed on to the subscriptions: what the agent sent so far can be
    /// seen by then.
    public func waitForSessionUpdatesHandled(sessionId: SessionId) async {
        await sessionUpdates.waitUntilHandled(sessionId)
    }

    /// Wait until no `session/update` for `sessionId` has arrived for
    /// `idleMilliseconds`, and every one that has has been handled — the history an
    /// agent replays for its `session/load` has stopped — as acpx's
    /// `waitForSessionUpdateDrain` does after every load. Throws
    /// ``SessionReplayDrainTimeout`` when that has not happened within
    /// `timeoutMilliseconds`. Other sessions' updates do not count.
    public func waitForSessionUpdateDrain(
        sessionId: SessionId, idleMilliseconds: Int = 80, timeoutMilliseconds: Int = 5000
    ) async throws {
        let idleMs = max(idleMilliseconds, 0)
        let timeoutMs = max(idleMs, timeoutMilliseconds)
        let idle = UInt64(idleMs) * 1_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + UInt64(timeoutMs) * 1_000_000
        while true {
            let (lastArrival, pending) = sessionUpdates.state(of: sessionId)
            let quietAt = max(start, lastArrival ?? start) + idle
            guard quietAt <= deadline else {
                // Updates only move it later: this wait can no longer end in time.
                try await Self.sleep(until: deadline)
                throw SessionReplayDrainTimeout(timeoutMilliseconds: timeoutMs)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now < quietAt {
                try await Self.sleep(until: quietAt)
                continue
            }
            if !pending { return }
            // One that arrived before the quiet began is still waiting for this actor:
            // let it be handled, while the replay is still kept back, then look again.
            guard now < deadline else { throw SessionReplayDrainTimeout(timeoutMilliseconds: timeoutMs) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Sleep until `instant`, in `DispatchTime` nanoseconds.
    private static func sleep(until instant: UInt64) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        if instant > now { try await Task.sleep(nanoseconds: instant - now) }
    }
}

/// The history an agent replays for `session/load` did not stop: its `session/update`s
/// kept arriving for the whole drain — acpx's error for the same case, which fails
/// the load.
public struct SessionReplayDrainTimeout: LocalizedError, Equatable, Sendable {
    public let timeoutMilliseconds: Int

    public init(timeoutMilliseconds: Int) {
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public var errorDescription: String? {
        "Timed out waiting for session replay drain after \(timeoutMilliseconds)ms"
    }
}
