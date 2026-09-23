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

    private let lock = NSLock()
    private var observer: Observer?
    /// While on, the agent's `session/update` notifications are not shown: they replay
    /// the history a `session/load` is restoring — acpx's
    /// `suppressReplaySessionUpdateMessages`.
    private var suppressingSessionUpdates = false

    public init(_ observer: Observer? = nil) {
        self.observer = observer
    }

    public func set(_ observer: Observer?) {
        lock.withLock { self.observer = observer }
    }

    /// Stop showing the agent's `session/update` notifications when `enabled`, and
    /// return what was in force before, for ``restoreSessionUpdateSuppression(_:)``.
    func applySessionUpdateSuppression(_ enabled: Bool) -> Bool {
        lock.withLock {
            let previous = suppressingSessionUpdates
            suppressingSessionUpdates = previous || enabled
            return previous
        }
    }

    func restoreSessionUpdateSuppression(_ previous: Bool) {
        lock.withLock { suppressingSessionUpdates = previous }
    }

    func observe(_ direction: JSONRPCPeer.WireDirection, _ body: Data) {
        lock.lock()
        let current = self.observer
        let suppressing = suppressingSessionUpdates
        lock.unlock()
        guard let observer = current else { return }
        if suppressing, direction == .inbound, Self.isSessionUpdateNotification(body) { return }
        observer(direction, body)
    }

    /// acpx's `isSessionUpdateNotification`: a `session/update` without an `id` member.
    static func isSessionUpdateNotification(_ body: Data) -> Bool {
        guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return false
        }
        return message["method"] as? String == "session/update" && message["id"] == nil
    }
}

/// A framing that shows every message body to a ``RawWireTap`` as it passes: an
/// outbound body just before it is written, an inbound one as soon as it is complete —
/// before it is decoded. A request is therefore always seen before its response.
public struct TappedFraming<Base: MessageFraming>: MessageFraming {
    private var base: Base
    private let tap: RawWireTap

    public init(_ base: Base, tap: RawWireTap) {
        self.base = base
        self.tap = tap
    }

    public func frame(_ body: Data) -> Data {
        tap.observe(.outbound, body)
        return base.frame(body)
    }

    public mutating func push(_ bytes: Data) -> [Data] {
        let bodies = base.push(bytes)
        for body in bodies { tap.observe(.inbound, body) }
        return bodies
    }
}
