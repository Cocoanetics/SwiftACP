import Foundation
import JSONFoundation
import JSONRPCPeer
import JSONRPCWire

/// The ACP message limit on a transport that reads through a ``MessageFraming`` — where
/// there is no ``AgentProcessTransport``: a line longer than allowed ends the connection
/// with ``AcpMessageLimitError``, as acpx's `countLineBytes` ends it, instead of growing
/// without bound.
///
/// ``Framing`` counts the bytes of the line in progress and, past the limit, reads no
/// further and tells ``Transport``, which closes the transport under it and, once
/// everything read before has gone out, ends its inbound stream with the error.
enum MessageLimit {
    /// Where the framing tells the transport the limit was passed.
    final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var error: AcpMessageLimitError?
        private var observer: (@Sendable () -> Void)?

        /// The limit passed, once it has been.
        var exceeded: AcpMessageLimitError? {
            lock.withLock { error }
        }

        func fire(_ error: AcpMessageLimitError) {
            let observer: (@Sendable () -> Void)? = lock.withLock {
                guard self.error == nil else { return nil }
                self.error = error
                return self.observer
            }
            observer?()
        }

        /// Run `observer` once the limit is passed — at once if it has been.
        func observe(_ observer: @escaping @Sendable () -> Void) {
            let passed: Bool = lock.withLock {
                self.observer = observer
                return error != nil
            }
            if passed { observer() }
        }
    }

    /// `base`, counting the bytes of the line in progress against `limit`.
    struct Framing<Base: MessageFraming>: MessageFraming {
        private var base: Base
        private let limit: Int
        private let signal: Signal
        private var retained = 0
        private var exceeded = false

        init(_ base: Base, limit: Int, signal: Signal) {
            self.base = base
            self.limit = limit
            self.signal = signal
        }

        func frame(_ body: Data) -> Data {
            base.frame(body)
        }

        mutating func push(_ bytes: Data) -> [Data] {
            guard !exceeded else { return [] }
            do {
                retained = try AgentOutputReader.countLineBytes(Array(bytes), retained: retained, limit: limit)
            } catch {
                exceeded = true
                signal.fire(AcpMessageLimitError(limit: limit))
                return []
            }
            return base.push(bytes)
        }
    }

    /// `base`, whose inbound stream ends with the limit's error once it is passed.
    final class Transport: JSONRPCMessageTransport, @unchecked Sendable {
        private let base: any JSONRPCMessageTransport
        private let signal: Signal

        init(_ base: any JSONRPCMessageTransport, signal: Signal) {
            self.base = base
            self.signal = signal
        }

        func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, any Error> {
            let inbound = base.makeInboundStream()
            let (stream, continuation) = AsyncThrowingStream<JSONRPCMessage, any Error>.makeStream()
            let signal = signal
            let forwarding = Task {
                var failure: (any Error)?
                do {
                    for try await message in inbound { continuation.yield(message) }
                } catch {
                    failure = error
                }
                if let exceeded = signal.exceeded {
                    continuation.finish(throwing: exceeded)
                } else {
                    continuation.finish(throwing: failure)
                }
            }
            continuation.onTermination = { _ in forwarding.cancel() }
            // Closed from a task of its own: the framing tells from the transport's reader.
            signal.observe { [base] in Task { base.close() } }
            return stream
        }

        func send(_ message: JSONRPCMessage) throws {
            try base.send(message)
        }

        func close() {
            base.close()
        }
    }
}
