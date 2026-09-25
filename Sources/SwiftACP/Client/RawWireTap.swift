import Foundation
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
/// it must be thread-safe and fast. Replace it at any time with ``set(_:)``.
public final class RawWireTap: @unchecked Sendable {
    public typealias Observer = @Sendable (JSONRPCPeer.WireDirection, Data) -> Void
    public typealias DeliveryObserver = @Sendable (Data, Delivery) -> Void

    /// How far an outbound body got on its way to the agent.
    public enum Delivery: Sendable {
        /// It is being written: from here on, the agent may have it.
        case writing
        /// Writing it failed: the agent does not have it.
        case failed
    }

    private let lock = NSLock()
    private var observer: Observer?
    private var deliveryObserver: DeliveryObserver?
    /// Sessions whose `session/update` notifications are not shown — their
    /// `session/load` is replaying history — with how many loads asked. acpx's
    /// `suppressReplaySessionUpdateMessages`, kept per session.
    private var replaySuppressed: [String: Int] = [:]

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
/// write itself happens out of its sight, so an outbound body counts as being written
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
