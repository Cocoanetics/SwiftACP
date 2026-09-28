import Foundation
import JSONFoundation
import JSONRPCPeer
import JSONRPCWire

/// Hands every JSON-RPC message body that crosses an agent's stdio to an observer, as
/// the bytes themselves: what the agent wrote (inbound), or what is about to be
/// written to it (outbound).
///
/// Decoding normalizes a message — key order, escapes, number forms — so anything that
/// must echo the wire the way acpx does needs these bytes rather than the decoded
/// value; see ``ACPAgentConnection/setWireObserver(_:)`` for the decoded form. The
/// observer runs on the transport's reader and writer tasks, possibly concurrently, so
/// it must be thread-safe and fast. Replace it at any time with ``set(_:)``. What the
/// agent writes to stderr goes to its own observer (``onStderr(_:)``), and so does what the
/// client notes of the agent (``onLog(_:)``).
public final class RawWireTap: @unchecked Sendable {
    public typealias Observer = @Sendable (JSONRPCPeer.WireDirection, Data) -> Void
    public typealias DeliveryObserver = @Sendable (Data, Delivery) -> Void
    public typealias StderrObserver = @Sendable (Data) -> Void
    public typealias LogObserver = @Sendable (String) -> Void

    /// How far an outbound body got on its way to the agent.
    public enum Delivery: Sendable {
        /// It is being written: from here on, the agent may have it.
        case writing
        /// It was written whole: the agent has it, unless it goes before reading it.
        case written
        /// Writing it failed: the agent does not have it.
        case failed
    }

    private let lock = NSLock()
    private var observer: Observer?
    private var deliveryObserver: DeliveryObserver?
    private var stderrObserver: StderrObserver?
    private var logObserver: LogObserver?
    /// Sessions whose `session/update` notifications are not shown — their
    /// `session/load` is replaying history — with how many loads asked. acpx's
    /// `suppressReplaySessionUpdateMessages`, kept per session.
    private var replaySuppressed: [String: Int] = [:]
    /// The `params` of each inbound `session/update` read and not yet handled, in order, once a
    /// connection takes them (``keepUpdateBodies()``, ``takeUpdateBody(sessionId:kind:)``).
    /// `nil` for an update without `params`, which its handler takes all the same (#242 review).
    private var updateBodies: [WireJSON?] = []
    /// Where the updates not yet taken begin in `updateBodies`.
    private var updateHead = 0
    private var keepsUpdateBodies = false

    public init(_ observer: Observer? = nil) {
        self.observer = observer
    }

    public func set(_ observer: Observer?) {
        lock.withLock { self.observer = observer }
    }

    /// Tell `observer` of each outbound body as it starts to be written to the agent, and
    /// again should the write fail. Until then the agent may have it, even should it act
    /// on it and exit before the writer hears the write went through, so a write that
    /// did not fail is as much as a sender can know of delivery. It runs on the
    /// transport's writer, so it must be thread-safe and fast.
    public func onDelivery(_ observer: DeliveryObserver?) {
        lock.withLock { deliveryObserver = observer }
    }

    /// Tell `observer` of each chunk the agent writes to stderr, as it is read — what acpx's
    /// client shows under `--verbose`. It runs on the thread that reads the agent, so it
    /// must be thread-safe and fast. Only an agent this process started has a stderr.
    public func onStderr(_ observer: StderrObserver?) {
        lock.withLock { stderrObserver = observer }
    }

    func stderr(_ bytes: Data) {
        lock.withLock { stderrObserver }?(bytes)
    }

    /// Tell `observer` of each line the client notes of the agent — acpx's `AcpClient.log`,
    /// which writes `[acpx] <line>` to its stderr under `--verbose`: the command it spawns,
    /// how it signs in, the protocol version `initialize` settles, a cancel it could not send,
    /// how the agent is ended. It runs on whichever thread notes the line, so it must be
    /// thread-safe and fast.
    public func onLog(_ observer: LogObserver?) {
        lock.withLock { logObserver = observer }
    }

    /// Note `line` of the agent (``onLog(_:)``).
    public func log(_ line: String) {
        lock.withLock { logObserver }?(line)
    }

    /// Stop showing `sessionId`'s `session/update` notifications until the matching
    /// ``endSuppressingReplay(of:)``.
    func beginSuppressingReplay(of sessionId: String) {
        lock.withLock { replaySuppressed[sessionId, default: 0] += 1 }
    }

    func endSuppressingReplay(of sessionId: String) {
        lock.withLock {
            guard let count = replaySuppressed[sessionId] else { return }
            replaySuppressed[sessionId] = count > 1 ? count - 1 : nil
        }
    }

    func delivery(_ body: Data, _ delivery: Delivery) {
        lock.withLock { deliveryObserver }?(body, delivery)
    }

    func observe(_ direction: JSONRPCPeer.WireDirection, _ body: Data) {
        if direction == .inbound { keepIfUpdate(body) }
        lock.lock()
        let current = self.observer
        let suppressed = replaySuppressed
        lock.unlock()
        guard let observer = current else { return }
        if direction == .inbound, !suppressed.isEmpty,
            let sessionId = Self.sessionUpdateSessionId(body), suppressed[sessionId] != nil {
            return
        }
        observer(direction, body)
    }

    /// Keep the bodies of inbound `session/update`s from now on, for the connection that handles
    /// them to take each as it does (#119).
    func keepUpdateBodies() {
        lock.withLock { keepsUpdateBodies = true }
    }

    /// Keep the `params` of each `session/update` notification in `body`, as the agent wrote
    /// them — the ones the peer takes as such: `body` decoded as the transports decode it
    /// (`JSONRPCMessage.decodeMessages`), a batch's messages each in turn. A body the peer does not
    /// take — one that only parses as JSON — is never kept, and neither is its method's spelling
    /// in the way: `"session\/update"` is the same method (#242 review).
    private func keepIfUpdate(_ body: Data) {
        guard lock.withLock({ keepsUpdateBodies }),
            let messages = try? JSONRPCMessage.decodeMessages(from: body), messages.contains(where: Self.isUpdate),
            let parsed = WireJSON(parsing: body)
        else { return }
        let written: [WireJSON] = if case .array(let items) = parsed { items } else { [parsed] }
        guard written.count == messages.count else { return }
        // One entry for each update — none of its `params` when it has none — so that the handler
        // of each takes its own.
        let kept: [WireJSON?] = zip(messages, written).filter { Self.isUpdate($0.0) }.map { $0.1["params"] }
        lock.withLock { updateBodies.append(contentsOf: kept) }
    }

    /// Whether `message` is a `session/update` notification.
    private static func isUpdate(_ message: JSONRPCMessage) -> Bool {
        guard case .notification(let notification) = message else { return false }
        return notification.method == "session/update"
    }

    /// The `params` of the update being handled — `sessionId`'s, of `kind` — as the agent wrote
    /// them: the oldest kept. One that is not it was never handled — its message did not reach
    /// the peer as a notification — and goes, so that the next is the next's.
    func takeUpdateBody(sessionId: String?, kind: String?) -> WireJSON? {
        lock.withLock {
            // The taken ones go once they are at least half of those kept: each is moved at most
            // once more, however long the batch it came in (#242 review).
            defer {
                if updateHead * 2 >= updateBodies.count {
                    updateBodies.removeFirst(updateHead)
                    updateHead = 0
                }
            }
            while updateHead < updateBodies.count {
                let params = updateBodies[updateHead]
                updateHead += 1
                // One without `params` is taken by the handler of an update without them, which
                // asks with no session and no kind.
                if params?["sessionId"]?.stringValue == sessionId,
                    params?["update"]?["sessionUpdate"]?.stringValue == kind {
                    return params
                }
            }
            return nil
        }
    }

    /// The session of a `session/update` notification — acpx's
    /// `isSessionUpdateNotification`: a `session/update` without an `id` member.
    static func sessionUpdateSessionId(_ body: Data) -> String? {
        guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
            message["method"] as? String == "session/update", message["id"] == nil,
            let params = message["params"] as? [String: Any]
        else { return nil }
        return params["sessionId"] as? String
    }
}

/// A framing that shows every message body to a ``RawWireTap`` as it passes: an
/// outbound body just before it is written, an inbound one as soon as it is complete —
/// before it is decoded. A request is therefore always seen before its response. The
/// write itself happens out of its sight, so an outbound body counts as written
/// (``RawWireTap/onDelivery(_:)``) once it is framed, and never as failed.
public struct TappedFraming<Base: MessageFraming>: MessageFraming {
    private var base: Base
    private let tap: RawWireTap

    public init(_ base: Base, tap: RawWireTap) {
        self.base = base
        self.tap = tap
    }

    public func frame(_ body: Data) -> Data {
        tap.observe(.outbound, body)
        tap.delivery(body, .writing)
        tap.delivery(body, .written)
        return base.frame(body)
    }

    public mutating func push(_ bytes: Data, emit: (Data) -> Void) throws {
        let tap = tap
        try base.push(bytes) { body in
            tap.observe(.inbound, body)
            emit(body)
        }
    }
}
