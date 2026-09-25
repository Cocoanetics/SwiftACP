import Foundation
import JSONFoundation
import JSONRPCPeer

/// Counts the agent's requests to the client — `fs/*`, `session/request_permission` —
/// that have arrived for a session and not yet been answered, so a turn can wait for
/// them before it ends.
///
/// Why it exists: the JSON-RPC peer reads messages in order but runs each inbound
/// request on its own task. An agent that asks for a write and then ends its turn
/// without awaiting the answer leaves that request's handler to run *later* — possibly
/// after the next turn has started and installed different permission handlers. The
/// write would then be judged by the wrong turn's mode (a `deny-all` turn's write
/// approved by the following `approve-all` one), and counted against the wrong turn.
///
/// acpx binds each such request to the turn that was active when it arrived, and
/// cancels it if that turn ends first (`captureDelegatedRequestOwner`). Here the turn
/// instead waits for them: a request is counted the moment it is *read* — in the
/// peer's wire hook, which runs inline in read order, so nothing that arrived before
/// the prompt's response can be missed — and ``ACPAgentConnection/prompt(_:)`` does
/// not return until every request counted for its session has been answered. They are
/// therefore always handled under their own turn's handlers, and recorded in its
/// permission counts.
///
/// Thread-safe: arrivals are recorded from the peer's actor, completions and waits
/// from the connection's.
final class InboundRequestLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: [SessionId: Int] = [:]
    /// How many requests have arrived for each session, ever — so a caller can tell one
    /// came and went since it last looked.
    private var arrivals: [SessionId: Int] = [:]
    private var idleWaiters: [SessionId: [CheckedContinuation<Bool, Never>]] = [:]
    /// Called when ``waitUntilIdle(_:)`` has to wait — lets a test release a request
    /// it is holding at exactly that point instead of guessing with a sleep.
    private var onWait: (@Sendable (SessionId) -> Void)?

    func setOnWait(_ hook: (@Sendable (SessionId) -> Void)?) {
        lock.withLock { onWait = hook }
    }

    /// The session a request's params name, if any — the same extraction on arrival and
    /// on completion, so the two always balance.
    static func sessionId(of params: JSONValue?) -> SessionId? {
        guard case .object(let object)? = params, case .string(let id)? = object["sessionId"]
        else { return nil }
        return id
    }

    func arrived(_ sessionId: SessionId) {
        lock.withLock {
            inFlight[sessionId, default: 0] += 1
            arrivals[sessionId, default: 0] += 1
        }
    }

    /// How many requests have arrived for `sessionId` so far.
    func arrivalCount(_ sessionId: SessionId) -> Int {
        lock.withLock { arrivals[sessionId] ?? 0 }
    }

    func finished(_ sessionId: SessionId) {
        let released: [CheckedContinuation<Bool, Never>] = lock.withLock {
            let remaining = (inFlight[sessionId] ?? 1) - 1
            if remaining > 0 {
                inFlight[sessionId] = remaining
                return []
            }
            inFlight[sessionId] = nil
            return idleWaiters.removeValue(forKey: sessionId) ?? []
        }
        released.forEach { $0.resume(returning: true) }
    }

    /// Return once every request that has arrived for `sessionId` has been answered —
    /// whether any was still open, and so waited for.
    @discardableResult
    func waitUntilIdle(_ sessionId: SessionId) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let (idle, hook): (Bool, (@Sendable (SessionId) -> Void)?) = lock.withLock {
                guard (inFlight[sessionId] ?? 0) > 0 else { return (true, nil) }
                idleWaiters[sessionId, default: []].append(continuation)
                return (false, onWait)
            }
            if idle { continuation.resume(returning: false) } else { hook?(sessionId) }
        }
    }
}

/// The caller's wire observer, read from the peer's hook on every message.
final class WireObserverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: (@Sendable (String) -> Void)?
    private var messageObserver: (@Sendable (JSONRPCPeer.WireDirection, JSONRPCMessage) -> Void)?

    func set(_ observer: (@Sendable (String) -> Void)?) {
        lock.withLock { self.observer = observer }
    }

    var current: (@Sendable (String) -> Void)? {
        lock.withLock { observer }
    }

    func setMessages(_ observer: (@Sendable (JSONRPCPeer.WireDirection, JSONRPCMessage) -> Void)?) {
        lock.withLock { messageObserver = observer }
    }

    var currentMessages: (@Sendable (JSONRPCPeer.WireDirection, JSONRPCMessage) -> Void)? {
        lock.withLock { messageObserver }
    }
}
