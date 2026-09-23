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
        lastSessionUpdate = ContinuousClock.now
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

    /// Wait until no `session/update` has arrived for `idle` — the history an agent
    /// replays for `session/load` has stopped — as acpx's `waitForSessionUpdateDrain`
    /// does after every load. Throws ``SessionReplayDrainTimeout`` when that has not
    /// happened within `timeout`.
    public func waitForSessionUpdateDrain(
        idle: Duration = .milliseconds(80), timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let idle = max(idle, .zero)
        let timeout = max(idle, timeout)
        let start = clock.now
        let deadline = start + timeout
        while true {
            let quietAt = max(start, lastSessionUpdate ?? start) + idle
            guard quietAt <= deadline else {
                // Updates only move it later: this wait can no longer end in time.
                try await clock.sleep(until: deadline)
                throw SessionReplayDrainTimeout(timeout: timeout)
            }
            if clock.now >= quietAt { return }
            try await clock.sleep(until: quietAt)
        }
    }
}

/// The history an agent replays for `session/load` did not stop: its `session/update`s
/// kept arriving for the whole drain — acpx's error for the same case, which fails
/// the load.
public struct SessionReplayDrainTimeout: LocalizedError, Equatable, Sendable {
    public let timeout: Duration

    public init(timeout: Duration) {
        self.timeout = timeout
    }

    public var errorDescription: String? {
        let (seconds, attoseconds) = timeout.components
        let milliseconds = seconds * 1000 + attoseconds / 1_000_000_000_000_000
        return "Timed out waiting for session replay drain after \(milliseconds)ms"
    }
}
