import Foundation
import JSONFoundation
import JSONRPCPeer

/// Which prompt each of the agent's owned requests belongs to — acpx's
/// `captureDelegatedRequestOwner` — told by wire order: the session's prompt in flight
/// when the request was read, if one was.
///
/// Owned are the requests acpx binds to a prompt: a permission question, a file read or
/// write, and starting a command (``ownedMethods``). The rest of the terminal requests —
/// its output, waiting for it, killing and releasing it — are served whatever becomes of
/// the prompt. Once a prompt's answer is read, what it owns is over (acpx's
/// `clearActivePrompt`): an owned request whose handler starts only then is answered
/// cancelled without being served (``isAnswered(_:)``).
///
/// Fed from the peer's wire hook, which runs inline as each message is read or written;
/// asked from where a request is served. A request is claimed there by its JSON-RPC id,
/// which its handler is given as the ACP SDK hands each handler its own request (#138):
/// two alike, read for different prompts, keep their own however their handlers start.
final class RequestOwnership: @unchecked Sendable {
    /// The agent's requests acpx binds to its prompt in flight.
    static let ownedMethods: Set<String> = [
        "session/request_permission", "fs/read_text_file", "fs/write_text_file", "terminal/create"
    ]

    private let lock = NSLock()
    /// Each session's prompt in flight on the wire, by its request id.
    private var inFlight: [SessionId: JSONRPCID] = [:]
    /// The sessions of the prompts in flight. The peer never reuses a request id, so a
    /// prompt no longer here was answered.
    private var sessions: [JSONRPCID: SessionId] = [:]
    /// Each owned request read and not yet served, by its id: the prompt that owns it, if
    /// one was in flight when it was read.
    private var unclaimed: [JSONRPCID: JSONRPCID?] = [:]
    /// What serves each prompt's owned requests, by request, stopped once its answer is
    /// read.
    private var serving: [JSONRPCID: [UUID: Task<Void, Never>]] = [:]

    /// Note `message` as it crosses the wire.
    func observe(_ direction: JSONRPCPeer.WireDirection, _ message: JSONRPCMessage) {
        switch (direction, message) {
        case (.outbound, .request(let request)) where request.method == "session/prompt":
            guard let sessionId = InboundRequestLedger.sessionId(of: request.params) else { return }
            lock.withLock {
                inFlight[sessionId] = request.id
                sessions[request.id] = sessionId
            }
        case (.inbound, .response(let response)):
            settle(response.id)
        case (.inbound, .errorResponse(let failure)):
            if let id = failure.id { settle(id) }
        case (.inbound, .request(let request)) where Self.ownedMethods.contains(request.method):
            let sessionId = InboundRequestLedger.sessionId(of: request.params)
            lock.withLock {
                unclaimed[request.id] = .some(sessionId.flatMap { inFlight[$0] })
            }
        default:
            break
        }
    }

    /// A prompt's answer was read: it is no longer in flight, and what serves the
    /// requests it owns stops.
    private func settle(_ id: JSONRPCID) {
        let stopping: [Task<Void, Never>] = lock.withLock {
            guard let sessionId = sessions.removeValue(forKey: id) else { return [] }
            if inFlight[sessionId] == id { inFlight[sessionId] = nil }
            return Array((serving.removeValue(forKey: id) ?? [:]).values)
        }
        stopping.forEach { $0.cancel() }
    }

    /// `task` serves the request `key` names, which `owner` owns: it stops once `owner`
    /// is answered — at once if it is already.
    func track(_ task: Task<Void, Never>, as key: UUID, ownedBy owner: JSONRPCID) {
        let answered: Bool = lock.withLock {
            guard sessions[owner] != nil else { return true }
            serving[owner, default: [:]][key] = task
            return false
        }
        if answered { task.cancel() }
    }

    /// The request `key` names was answered: nothing of it is left to stop. What serves
    /// `owner`'s other requests still stops at its answer.
    func untrack(_ key: UUID, ownedBy owner: JSONRPCID) {
        lock.withLock {
            serving[owner]?[key] = nil
            if serving[owner]?.isEmpty == true { serving[owner] = nil }
        }
    }

    /// The prompt the request `id` about to be served belongs to, or `nil` if none was in
    /// flight when it was read.
    func claim(_ id: JSONRPCID) -> JSONRPCID? {
        lock.withLock { unclaimed.removeValue(forKey: id) ?? nil }
    }

    /// Whether `prompt`, which was in flight when a request it owns was read, has been
    /// answered since.
    func isAnswered(_ prompt: JSONRPCID) -> Bool {
        lock.withLock { sessions[prompt] == nil }
    }
}
