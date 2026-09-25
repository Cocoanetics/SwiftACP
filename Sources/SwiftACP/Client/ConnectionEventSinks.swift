import Foundation
import JSONFoundation
import JSONRPCPeer

/// A connection's ``ConnectionEvent`` subscriptions, reachable from the peer's wire hook
/// as well as from the connection itself: what the wire hook announces keeps its place
/// among the messages around it (see ``WireOrderedEvents``).
final class EventSinks: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [UUID: AsyncStream<ConnectionEvent>.Continuation] = [:]

    func add(_ sink: AsyncStream<ConnectionEvent>.Continuation, as id: UUID) {
        lock.withLock { sinks[id] = sink }
    }

    func yield(_ event: ConnectionEvent) {
        for sink in lock.withLock({ Array(sinks.values) }) { sink.yield(event) }
    }

    /// End one subscription's stream. It is removed once the stream has ended.
    func finish(_ id: UUID) {
        lock.withLock { sinks[id] }?.finish()
    }

    func remove(_ id: UUID) {
        lock.withLock { sinks[id] = nil }
    }

    /// End every subscription's stream, and forget them all.
    func finishAll() {
        let all = lock.withLock {
            defer { sinks.removeAll() }
            return Array(sinks.values)
        }
        for sink in all { sink.finish() }
    }
}

/// What the connection announces from the peer's wire hook, as the messages it is about
/// are read: a request of the agent's arriving, and a prompt's answer. The peer hands
/// each notification on before it reads the next message, so every update the agent
/// sent before either has been handed on by then, and none it sent after has been yet:
/// each keeps its place among them, as acpx's formatter sees every message in order.
/// Announced from where they are served or awaited — tasks of their own — they would not.
final class WireOrderedEvents: @unchecked Sendable {
    private let lock = NSLock()
    /// The `session/prompt` requests on the wire, with their sessions, until answered.
    private var sessions: [JSONRPCID: SessionId] = [:]

    /// Note `message` as it crosses the wire, announcing to `sinks` what it tells.
    func observe(_ direction: JSONRPCPeer.WireDirection, _ message: JSONRPCMessage, announcingTo sinks: EventSinks) {
        switch (direction, message) {
        case (.inbound, .request(let request)):
            let sessionId = InboundRequestLedger.sessionId(of: request.params)
            sinks.yield(.inboundRequest(InboundRequest(method: request.method, sessionId: sessionId)))
        case (.outbound, .request(let request)) where request.method == "session/prompt":
            guard let sessionId = InboundRequestLedger.sessionId(of: request.params) else { return }
            lock.withLock { sessions[request.id] = sessionId }
        case (.inbound, .response(let response)):
            guard let sessionId = lock.withLock({ sessions.removeValue(forKey: response.id) }),
                  let answer = try? (response.result ?? .null).decoded(PromptResponse.self)
            else { return }
            sinks.yield(.promptAnswered(sessionId, answer))
        case (.inbound, .errorResponse(let failure)):
            guard let id = failure.id else { return }
            lock.withLock { _ = sessions.removeValue(forKey: id) }
        default:
            break
        }
    }
}
