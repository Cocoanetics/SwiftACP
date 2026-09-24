import Dispatch
import Foundation

/// The agent's `session/update`s per session: counted the moment each is read, in the
/// peer's wire hook, inline and in read order, and again once the connection has
/// handled it; with the time of the latest arrival.
///
/// The replay drain goes by it. A load's replay has stopped once nothing has arrived
/// for the idle window and everything that arrived has been handled — while the
/// load's suppression still held. An update read just before the quiet began can
/// still be waiting for the connection's actor; ending the suppression then would
/// deliver it after all. acpx waits on the same two counts
/// (`observedSessionUpdates`, `processedSessionUpdates`).
///
/// Thread-safe: arrivals are recorded from the peer's actor, handling from the
/// connection's.
final class SessionUpdateLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals: [SessionId: UInt64] = [:]
    private var handled: [SessionId: UInt64] = [:]
    private var lastArrival: [SessionId: UInt64] = [:]

    func arrived(_ sessionId: SessionId) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            arrivals[sessionId, default: 0] += 1
            lastArrival[sessionId] = now
        }
    }

    func finished(_ sessionId: SessionId) {
        lock.withLock { handled[sessionId, default: 0] += 1 }
    }

    /// When `sessionId`'s latest update arrived, in `DispatchTime` nanoseconds, and
    /// whether one that has arrived is still to be handled.
    func state(of sessionId: SessionId) -> (lastArrival: UInt64?, pending: Bool) {
        lock.withLock {
            (lastArrival[sessionId], arrivals[sessionId, default: 0] > handled[sessionId, default: 0])
        }
    }
}
