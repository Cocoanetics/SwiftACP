import Foundation
import JSONFoundation
import JSONRPCPeer

/// Two `JSONRPCMessageTransport`s wired back-to-back in memory: what one end
/// writes, the other reads. Lets an ACP client and an ``ACPAgentServer`` run in the
/// same process — for embedding an agent inside an app, or for hermetic protocol
/// tests with no subprocess.
///
/// As an in-memory transport it does no framing: it hands whole ``JSONRPCMessage``
/// values straight across, exactly the seam ``JSONRPCMessageTransport`` defines.
public final class LoopbackTransport: JSONRPCMessageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation?
    private var pending: [JSONRPCMessage] = []
    private var deliver: (@Sendable (JSONRPCMessage) -> Void)?
    private var closePeer: (@Sendable () -> Void)?
    private var isClosed = false

    /// A connected pair: hand `client` to an ACP client connection and `server`
    /// to ``ACPAgentServer``. Closing either end ends the other's inbound stream.
    public static func pair() -> (client: LoopbackTransport, server: LoopbackTransport) {
        let a = LoopbackTransport()
        let b = LoopbackTransport()
        a.deliver = { [weak b] message in b?.receive(message) }
        b.deliver = { [weak a] message in a?.receive(message) }
        a.closePeer = { [weak b] in b?.close() }
        b.closePeer = { [weak a] in a?.close() }
        return (a, b)
    }

    private func receive(_ message: JSONRPCMessage) {
        lock.lock()
        if let continuation {
            lock.unlock()
            continuation.yield(message)
        } else {
            pending.append(message)
            lock.unlock()
        }
    }

    public func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            let buffered = pending
            pending = []
            let closed = isClosed
            lock.unlock()
            for message in buffered { continuation.yield(message) }
            if closed { continuation.finish() }
        }
    }

    public func send(_ message: JSONRPCMessage) throws {
        lock.lock()
        let closed = isClosed
        let send = deliver
        lock.unlock()
        guard !closed else { throw JSONRPCPeerError.closed }
        send?(message)
    }

    public func close() {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        let continuation = self.continuation
        self.continuation = nil
        let peerClose = closePeer
        closePeer = nil
        deliver = nil
        lock.unlock()
        continuation?.finish()
        peerClose?()
    }
}
