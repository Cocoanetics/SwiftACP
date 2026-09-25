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
    @Test(.timeLimit(.minutes(1)))
    func replacedSubscriptionsCarryEachEventOnce() async throws {
        let connection = ACPAgentConnection(transport: LoopbackTransport.pair().0)
        let sinks = await connection.eventSinks
        let total = 100_000
        Thread {
            for index in 0..<total {
                sinks.yield(.inboundRequest(InboundRequest(method: String(index), sessionId: nil)))
                if index % 50 == 0 { Thread.sleep(forTimeInterval: 0.000_02) }
            }
            sinks.yield(.inboundRequest(InboundRequest(method: "end", sessionId: nil)))
        }.start()

        let first = await connection.makeEventSubscription()
        var subscription = first.id
        var events = first.stream.makeAsyncIterator()
        var replacement: (id: UUID, stream: AsyncStream<ConnectionEvent>)?
        var ending = false
        var seen: [Int] = []
        var replacements = 0
        while true {
            guard let event = await events.next() else {
                // This stream has ended: it was replaced, or it was the last.
                guard let next = replacement else { break }
                (subscription, events, replacement) = (next.id, next.stream.makeAsyncIterator(), nil)
                if ending { await connection.endSubscription(subscription) }
                continue
            }
            guard case .inboundRequest(let request) = event else { continue }
            guard let index = Int(request.method) else {
                // Every event is out: the stream they end in stops once it has handed them on.
                ending = true
                if replacement == nil { await connection.endSubscription(subscription) }
                continue
            }
            seen.append(index)
            // Replaced while the events keep coming; the old stream ends by itself.
            if replacement == nil, !ending, seen.count % 500 == 0 {
                replacement = await connection.replaceEventSubscription(subscription)
                replacements += 1
            }
        }
        #expect(seen == Array(0..<total), "\(seen.count) of \(total)")
        #expect(replacements > 10)
    }
}
