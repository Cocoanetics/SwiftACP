import Dispatch
import Foundation
import JSONFoundation

// The agent's `session/update`s: fanned out to the subscriptions — except while a
// `session/load` replays history the caller already has — and waited on until that
// replay stops.
//
// Split from `ACPAgentConnection.swift` to keep that file inside the 500-line limit;
// the members this reaches are internal rather than private so both halves can.
extension ACPAgentConnection {
    /// A notification from the agent: a `session/update` goes to every subscription,
    /// unless a replay is being kept from them.
    func handleIncomingNotification(method: String, params: JSONValue?) async {
        guard method == "session/update", let params,
            let notification = try? params.decoded(SessionNotification.self)
        else { return }
        lastSessionUpdate = DispatchTime.now().uptimeNanoseconds
        if suppressingSessionUpdates { return }
        for sink in updateSinks.values {
            sink.yield(notification)
        }
        for sink in eventSinks.values {
            sink.yield(.update(notification))
        }
    }

    /// Stop delivering `session/update`s when `enabled`, and return what was in force
    /// before, for ``restoreSessionUpdateSuppression(_:)``.
    func applySessionUpdateSuppression(_ enabled: Bool) -> Bool {
        let previous = suppressingSessionUpdates
        suppressingSessionUpdates = previous || enabled
        return previous
    }

    func restoreSessionUpdateSuppression(_ previous: Bool) {
        suppressingSessionUpdates = previous
    }

    /// Wait until no `session/update` has arrived for `idleMilliseconds` — the history
    /// an agent replays for `session/load` has stopped — as acpx's
    /// `waitForSessionUpdateDrain` does after every load. Throws
    /// ``SessionReplayDrainTimeout`` when that has not happened within
    /// `timeoutMilliseconds`.
    public func waitForSessionUpdateDrain(
        idleMilliseconds: Int = 80, timeoutMilliseconds: Int = 5000
    ) async throws {
        let idleMs = max(idleMilliseconds, 0)
        let timeoutMs = max(idleMs, timeoutMilliseconds)
        let idle = UInt64(idleMs) * 1_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + UInt64(timeoutMs) * 1_000_000
        while true {
            let quietAt = max(start, lastSessionUpdate ?? start) + idle
            guard quietAt <= deadline else {
                // Updates only move it later: this wait can no longer end in time.
                try await Self.sleep(until: deadline)
                throw SessionReplayDrainTimeout(timeoutMilliseconds: timeoutMs)
            }
            if DispatchTime.now().uptimeNanoseconds >= quietAt { return }
            try await Self.sleep(until: quietAt)
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
