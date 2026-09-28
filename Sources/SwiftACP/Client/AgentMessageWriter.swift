#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import JSONRPCPeer

/// Writes the agent's messages to its stdin, in order, on a thread of its own — a write
/// waits while the agent does not read — and closes stdin once told to finish and the
/// queue is empty. Each body is shown to the tap as it is queued, in the sender's
/// context and in the order it is written, and told of again as it starts to be
/// written and should the write fail (``RawWireTap/onDelivery(_:)``).
final class MessageWriter: @unchecked Sendable {
    private let process: ChildProcess
    private let tap: RawWireTap
    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)
    private var queue: [Data] = []
    private var finishing = false
    /// Told, once, that a write failed. Set before ``start()``.
    var onFailure: (@Sendable () -> Void)?

    init(process: ChildProcess, tap: RawWireTap) {
        self.process = process
        self.tap = tap
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "acp.agent.stdin"
        thread.start()
    }

    /// Queue `body` to be written. Throws ``JSONRPCPeerError/closed`` once finishing.
    func enqueue(_ body: Data) throws {
        try lock.withLock {
            guard !finishing else { throw JSONRPCPeerError.closed }
            tap.observe(.outbound, body)
            queue.append(body)
        }
        available.signal()
    }

    /// Write what is queued, then close stdin — Node's `stdin.end()`.
    func finish() {
        let first: Bool = lock.withLock {
            defer { finishing = true }
            return !finishing
        }
        if first { available.signal() }
    }

    private func run() {
        var failed = false
        while true {
            available.wait()
            let (next, done): (Data?, Bool) = lock.withLock {
                queue.isEmpty ? (nil, finishing) : (queue.removeFirst(), false)
            }
            if let next {
                guard !failed else { continue }
                tap.delivery(next, .writing)
                do {
                    try process.write(Array(next) + [0x0A])
                    tap.delivery(next, .written)
                } catch {
                    // The agent closed its stdin — mostly by exiting, which is noticed
                    // on its own. What remains is not written.
                    tap.delivery(next, .failed)
                    failed = true
                    onFailure?()
                }
                continue
            }
            if done { break }
        }
        process.closeInput()
    }
}
#endif
