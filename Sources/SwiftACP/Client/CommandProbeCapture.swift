#if os(macOS) || os(Linux) || os(Windows)
import Foundation

/// A probe's output as it comes, and its end: Node's `close` — exited, both pipes at their end.
/// The outcome is kept once settled, for a caller that asks for it only then (#263 review).
final class CommandProbeCapture: @unchecked Sendable {
    /// Which of the probe's pipes output came from.
    enum Stream {
        case stdout, stderr
    }

    private let lock = NSLock()
    private var stdout: [UInt8] = []
    private var stderr: [UInt8] = []
    private var closedPipes = 0
    private var hasExited = false
    /// The output once settled: `.some(nil)` past its time, or given up.
    private var outcome: String??
    private var closeWaiter: CheckedContinuation<String?, Never>?
    private var exitWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func append(_ output: Stream, _ bytes: [UInt8]) {
        lock.withLock {
            guard outcome == nil else { return }
            if output == .stdout { stdout += bytes } else { stderr += bytes }
        }
    }

    func pipeClosed() {
        lock.withLock { closedPipes += 1 }
        settleIfClosed()
    }

    func exited() {
        let waiters: [CheckedContinuation<Bool, Never>] = lock.withLock {
            hasExited = true
            defer { exitWaiters = [:] }
            return Array(exitWaiters.values)
        }
        waiters.forEach { $0.resume(returning: true) }
        settleIfClosed()
    }

    /// Stop waiting for the output: whoever waits, or asks later, has none.
    func giveUp() {
        settle(nil)
    }

    private func settleIfClosed() {
        let written: ([UInt8], [UInt8])? = lock.withLock {
            hasExited && closedPipes == 2 ? (stdout, stderr) : nil
        }
        guard let (out, err) = written else { return }
        settle(String(decoding: out, as: UTF8.self) + "\n" + String(decoding: err, as: UTF8.self))
    }

    private func settle(_ output: String?) {
        let waiter: CheckedContinuation<String?, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = .some(output)
            defer { closeWaiter = nil }
            return closeWaiter
        }
        waiter?.resume(returning: output)
    }

    /// The output once the probe closed — kept, if it came first — or `nil` past `milliseconds`.
    func output(within milliseconds: Int) async -> String? {
        await withCheckedContinuation { continuation in
            let settled: String?? = lock.withLock {
                if let outcome { return outcome }
                closeWaiter = continuation
                return nil
            }
            if let settled {
                continuation.resume(returning: settled)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                self.settle(nil)
            }
        }
    }

    /// Whether the probe exits within `milliseconds`.
    func exit(within milliseconds: Int) async -> Bool {
        let key = UUID()
        return await withCheckedContinuation { continuation in
            let done: Bool = lock.withLock {
                if hasExited { return true }
                exitWaiters[key] = continuation
                return false
            }
            if done {
                continuation.resume(returning: true)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                self.lock.withLock { self.exitWaiters.removeValue(forKey: key) }?.resume(returning: false)
            }
        }
    }
}
#endif
