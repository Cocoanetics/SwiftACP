import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// An event subscription replaced by another hands each event to exactly one of the two:
/// the old stream ends with every event before the replacement, and the new one carries
/// every event after — which `exec`'s attempts and pauses rely on, each ending at one
/// point in the events (#106).
struct EventSubscriptionTests {
    /// Events yielded from another thread all along, while the subscription is replaced
    /// again and again: the streams, one after another, carry each event once, in order.
    /// The events keep coming until the last replacement is made, however fast either side.
    @Test(.timeLimit(.minutes(1)))
    func replacedSubscriptionsCarryEachEventOnce() async throws {
        let connection = ACPAgentConnection(transport: LoopbackTransport.pair().0)
        let sinks = await connection.eventSinks
        let replaced = Stop()
        // Subscribed before the first event is yielded: every one has a stream to go to.
        let first = await connection.makeEventSubscription()
        Thread {
            var index = 0
            while !replaced.isSet {
                sinks.yield(.inboundRequest(InboundRequest(method: String(index), sessionId: nil)))
                index += 1
                if index % 50 == 0 { Thread.sleep(forTimeInterval: 0.000_02) }
            }
            // The last word: how many came.
            sinks.yield(.inboundRequest(InboundRequest(method: "end \(index)", sessionId: nil)))
        }.start()

        var subscription = first.id
        var events = first.stream.makeAsyncIterator()
        var replacement: (id: UUID, stream: AsyncStream<ConnectionEvent>)?
        var total: Int?
        var seen: [Int] = []
        var replacements = 0
        while true {
            guard let event = await events.next() else {
                // This stream has ended: it was replaced, or it was the last.
                guard let next = replacement else { break }
                (subscription, events, replacement) = (next.id, next.stream.makeAsyncIterator(), nil)
                if total != nil { await connection.endSubscription(subscription) }
                continue
            }
            guard case .inboundRequest(let request) = event else { continue }
            guard let index = Int(request.method) else {
                // Every event is out: the stream they end in stops once it has handed them on.
                total = Int(request.method.dropFirst("end ".count))
                if replacement == nil { await connection.endSubscription(subscription) }
                continue
            }
            seen.append(index)
            // Replaced while the events keep coming; the old stream ends by itself.
            if replacement == nil, replacements < 50, seen.count % 200 == 0 {
                replacement = await connection.replaceEventSubscription(subscription)
                replacements += 1
                if replacements == 50 { replaced.set() }
            }
        }
        let count = try #require(total)
        #expect(seen == Array(0..<count), "\(seen.count) of \(count)")
        #expect(replacements == 50)
    }

    /// Set once, from the test; read from the thread yielding.
    private final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isSet: Bool { lock.withLock { stopped } }
        func set() { lock.withLock { stopped = true } }
    }
}
