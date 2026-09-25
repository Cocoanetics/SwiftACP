import Foundation
import JSONFoundation
import JSONRPCPeer

/// A connection's ``ConnectionEvent`` subscriptions, reachable from the peer's wire hook
/// as well as from the connection itself: a prompt's answer is announced as it is read,
/// in order with the messages around it (see ``PromptsOnTheWire``).
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

/// The `session/prompt` requests on the wire, with their sessions, until their answers
/// are read: how the wire hook knows a prompt's answer when it reads one.
final class PromptsOnTheWire: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [JSONRPCID: SessionId] = [:]

    /// Note `message` as it crosses the wire: a prompt going out, or its answer coming
    /// back — announced to `sinks` then and there. Every update the agent sent before the
    /// answer was handed on before it was read, and none it sent after has been yet, so
    /// the answer keeps its place among them, as acpx's formatter sees it. Announced from
    /// the call that sent the prompt, as it resumes, it would not.
    func observe(_ direction: JSONRPCPeer.WireDirection, _ message: JSONRPCMessage, announcingTo sinks: EventSinks) {
        switch (direction, message) {
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
