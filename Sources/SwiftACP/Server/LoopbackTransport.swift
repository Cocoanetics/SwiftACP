import Foundation

/// Two `MessageTransport`s wired back-to-back in memory: what one end writes,
/// the other reads. Lets an ACP client and an ``ACPAgentServer`` run in the same
/// process — for embedding an agent inside an app, or for hermetic protocol
/// tests with no subprocess.
public final class LoopbackTransport: MessageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var pending: [String] = []
    private var deliver: (@Sendable (String) -> Void)?
    private var closePeer: (@Sendable () -> Void)?
    private var isClosed = false

    /// A connected pair: hand `client` to an ACP client connection and `server`
    /// to ``ACPAgentServer``. Closing either end ends the other's inbound stream.
    public static func pair() -> (client: LoopbackTransport, server: LoopbackTransport) {
        let a = LoopbackTransport()
        let b = LoopbackTransport()
        a.deliver = { [weak b] line in b?.receive(line) }
        b.deliver = { [weak a] line in a?.receive(line) }
        a.closePeer = { [weak b] in b?.close() }
        b.closePeer = { [weak a] in a?.close() }
        return (a, b)
    }

    private func receive(_ line: String) {
        lock.lock()
        if let continuation {
            lock.unlock()
            continuation.yield(line)
        } else {
            pending.append(line)
            lock.unlock()
        }
    }

    public func makeInboundStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            let buffered = pending
            pending = []
            let closed = isClosed
            lock.unlock()
            for line in buffered { continuation.yield(line) }
            if closed { continuation.finish() }
        }
    }

    public func write(_ line: String) throws {
        lock.lock()
        let closed = isClosed
        let send = deliver
        lock.unlock()
        guard !closed else { throw TransportError.closed }
        send?(line)
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
