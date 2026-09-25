import Foundation
import JSONFoundation

// The connection's subscriptions: its `session/update`s, and the richer
// ``ConnectionEvent`` stream, each opened, ended and replaced here.
//
// Split from `ACPAgentConnection.swift` to keep that file inside the 500-line limit.
extension ACPAgentConnection {
    /// A new stream of every `session/update` notification across all sessions.
    /// Subscribe before prompting so no updates are missed.
    public func updates() -> AsyncStream<SessionNotification> {
        makeSubscription().stream
    }

    /// Like ``updates()`` but also returns a token so the caller can deliberately
    /// end the stream (draining buffered values first) — used by one-shot helpers.
    public func makeSubscription() -> (id: UUID, stream: AsyncStream<SessionNotification>) {
        var capturedId = UUID()
        let stream = AsyncStream<SessionNotification> { continuation in
            let id = UUID()
            capturedId = id
            updateSinks[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSink(id) }
            }
        }
        return (capturedId, stream)
    }

    /// Like ``makeSubscription()``, but the stream carries every ``ConnectionEvent``
    /// — each `session/update` plus the client operations this connection reports
    /// (a permission refusal that may end the turn) — in wire order.
    public func makeEventSubscription() -> (id: UUID, stream: AsyncStream<ConnectionEvent>) {
        var capturedId = UUID()
        let stream = AsyncStream<ConnectionEvent> { continuation in
            let id = UUID()
            capturedId = id
            eventSinks.add(continuation, as: id)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSink(id) }
            }
        }
        return (capturedId, stream)
    }

    /// A new stream of every ``ConnectionEvent`` across all sessions. Subscribe
    /// before prompting so no event is missed.
    public func events() -> AsyncStream<ConnectionEvent> {
        makeEventSubscription().stream
    }

    /// Finish a subscription's stream; the consumer still receives buffered values.
    public func endSubscription(_ id: UUID) {
        updateSinks[id]?.finish()
        eventSinks.finish(id)
    }

    private func removeSink(_ id: UUID) {
        updateSinks[id] = nil
        eventSinks.remove(id)
    }

    /// End event subscription `id` and open another in its place, at one point in the
    /// events: `id`'s stream ends with every event before it, and the new stream carries
    /// every event after — none missed, none twice.
    public func replaceEventSubscription(_ id: UUID) -> (id: UUID, stream: AsyncStream<ConnectionEvent>) {
        let replacement = UUID()
        let stream = AsyncStream<ConnectionEvent> { continuation in
            continuation.onTermination = { [eventSinks] _ in eventSinks.remove(replacement) }
            eventSinks.replace(id, with: continuation, as: replacement)
        }
        return (replacement, stream)
    }
}
