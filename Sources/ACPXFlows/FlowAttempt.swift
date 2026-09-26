import ACPXCore
import Foundation
import SwiftACP

/// acpx's `TimeoutError`: `Timed out after <ms>ms`, which the CLI reports as `TIMEOUT`
/// (exit 3), as any timeout.
public struct FlowTimeoutError: Error, LocalizedError, OutputErrorMeta, Equatable {
    public let timeoutMs: Double
    public var errorDescription: String? { "Timed out after \(WireJSON.javaScriptString(for: timeoutMs))ms" }
    public var outputCode: String? { "TIMEOUT" }
    public var detailCode: String? { nil }
    public var origin: String? { nil }
}

/// acpx's `InterruptedError`: `Interrupted`.
public struct FlowInterruptedError: Error, LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { "Interrupted" }
}

/// acpx's `AggregateError` for an attempt whose work failed on its way out.
struct FlowAttemptCleanupError: Error, LocalizedError {
    let errors: [Error]
    var errorDescription: String? { "Flow attempt cleanup failed" }
}

/// An attempt that has finished taking work (acpx's `assertActive`).
struct FlowAttemptFinished: Error, LocalizedError {
    var errorDescription: String? { "Flow attempt has finished accepting work" }
}

/// acpx's `FlowAttempt` (`src/flows/attempt.ts`): one node attempt, which owns admitting
/// and finishing the runtime work done for it.
///
/// - It is cancelled at its deadline, with ``FlowTimeoutError``, or when the run is
///   interrupted; ``run(_:)`` then ends at once with the reason, whatever the node's own
///   callback is still doing — a callback may ignore cancellation, as acpx's may.
/// - Work it owns (``own(_:bestEffort:)``) is waited for before the attempt ends, and a
///   failure of that work is the attempt's.
/// - Cancellations registered with it run when it is cancelled.
final class FlowAttempt: @unchecked Sendable {
    let nodeId: String
    let attemptId: String
    let startedAt: String

    private let timeoutMs: Double?
    private let deadline: ContinuousClock.Instant?
    private let lock = NSLock()
    private var accepting = true
    private var finished = false
    private var reason: Error?
    private var signal = "SIGTERM"
    private var abortHandlers: [UUID: @Sendable (Error) -> Void] = [:]
    private var cancellations: [UUID: @Sendable (String) async throws -> Void] = [:]
    private var pending: [UUID: Task<Error?, Never>] = [:]
    private var cleanupFailures: [Error] = []
    private var timer: Task<Void, Never>?
    private var onCancel: (@Sendable (Error) -> Void)?

    init(nodeId: String, attemptId: String, startedAt: String, timeoutMs: Double?) {
        self.nodeId = nodeId
        self.attemptId = attemptId
        self.startedAt = startedAt
        if let timeoutMs, timeoutMs > 0 {
            self.timeoutMs = timeoutMs
            deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        } else {
            self.timeoutMs = nil
            deadline = nil
        }
        if let timeoutMs = self.timeoutMs {
            timer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                guard !Task.isCancelled else { return }
                self?.cancel(FlowTimeoutError(timeoutMs: timeoutMs))
            }
        }
    }

    /// Told the reason the attempt is cancelled for, when it is — so the host can abort
    /// the callback's `ctx.signal`.
    func setOnCancel(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.withLock { onCancel = handler }
    }

    /// Whether it still takes work: not cancelled, and not done.
    var active: Bool { lock.withLock { accepting && reason == nil } }

    /// Why it was cancelled, if it was.
    var abortReason: Error? { lock.withLock { reason } }

    /// The signal a cancellation stops shell processes with.
    var terminationSignal: String { lock.withLock { signal } }

    /// acpx's `assertActive`.
    func assertActive() throws {
        checkDeadline()
        try lock.withLock {
            if let reason { throw reason }
            if !accepting { throw FlowAttemptFinished() }
        }
    }

    /// acpx's `remainingTimeoutMs`: at least 1, none without a deadline.
    func remainingTimeoutMs() throws -> Double? {
        try assertActive()
        guard let deadline else { return nil }
        let left = deadline - ContinuousClock.now
        let milliseconds = Double(left.components.seconds) * 1000 + Double(left.components.attoseconds) / 1e15
        return max(1, milliseconds.rounded(.up))
    }

    /// acpx's `cancel`: no more work taken, `reason` given to whatever waits, and the
    /// registered cancellations started.
    func cancel(_ error: Error, signal terminationSignal: String = "SIGTERM") {
        let told: Cancelled? = lock.withLock {
            guard !finished, reason == nil else { return nil }
            accepting = false
            signal = terminationSignal
            reason = error
            defer { abortHandlers.removeAll() }
            return Cancelled(
                handlers: Array(abortHandlers.values), cancellations: Array(cancellations.values), notify: onCancel)
        }
        guard let told else { return }
        told.notify?(error)
        for handler in told.handlers { handler(error) }
        for cancellation in told.cancellations { track(cancellation) }
    }

    /// Who a cancellation tells, taken under the lock.
    private struct Cancelled {
        let handlers: [@Sendable (Error) -> Void]
        let cancellations: [@Sendable (String) async throws -> Void]
        let notify: (@Sendable (Error) -> Void)?
    }

    /// acpx's `registerCancellation`: run at once if the attempt is not active.
    @discardableResult
    func registerCancellation(_ cancel: @escaping @Sendable (String) async throws -> Void) -> () -> Void {
        let id = UUID()
        let registered: Bool = lock.withLock {
            guard accepting, reason == nil else { return false }
            cancellations[id] = cancel
            return true
        }
        guard registered else {
            track(cancel)
            return {}
        }
        return { [weak self] in _ = self?.lock.withLock { self?.cancellations.removeValue(forKey: id) } }
    }

    /// acpx's `own`: runtime work the attempt waits for before it ends — never a node's
    /// callback, which may ignore cancellation. With `bestEffort`, its failure is not the
    /// attempt's.
    func own<T: Sendable>(bestEffort: Bool = false, _ operation: @escaping @Sendable () async throws -> T)
        async throws -> T {
        try assertActive()
        let work = Task { () async throws -> T in
            let value = try await operation()
            self.checkDeadline()
            if let reason = self.abortReason { throw reason }
            return value
        }
        let id = UUID()
        let outcome = Task<Error?, Never> {
            switch await work.result {
            case .success: return nil
            case .failure(let error): return bestEffort ? nil : error
            }
        }
        lock.withLock { pending[id] = outcome }
        Task { [weak self] in
            _ = await outcome.value
            _ = self?.lock.withLock { self?.pending.removeValue(forKey: id) }
        }
        return try await work.value
    }

    /// acpx's `run`: `body`, or the reason the attempt was cancelled, whichever comes
    /// first; then the attempt's owned work, waited for.
    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        defer { finish() }
        do {
            try assertActive()
            let value = try await race(body)
            lock.withLock { accepting = false }
            let errors = await drain()
            if !errors.isEmpty { throw cleanupError(errors) }
            checkDeadline()
            if let reason = abortReason { throw reason }
            return value
        } catch {
            cancel(error)
            let errors = await drain()
            if !errors.isEmpty { throw cleanupError([error] + errors) }
            throw error
        }
    }

    /// `body`'s result, unless the attempt is cancelled first — then its reason, at once:
    /// the body goes on in the background, as a JavaScript promise does, so a callback
    /// that never returns cannot hold the run.
    private func race<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        defer { _ = lock.withLock { abortHandlers.removeValue(forKey: id) } }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let first = FirstResult(continuation)
            Task {
                do {
                    first.settle(.success(try await body()))
                } catch {
                    first.settle(.failure(error))
                }
            }
            let already: Error? = lock.withLock {
                if let reason { return reason }
                abortHandlers[id] = { first.settle(.failure($0)) }
                return nil
            }
            if let already { first.settle(.failure(already)) }
        }
    }

    private func finish() {
        lock.withLock {
            accepting = false
            finished = true
        }
        timer?.cancel()
    }

    /// acpx's `checkDeadline`: past it, the attempt is timed out.
    private func checkDeadline() {
        guard let deadline, let timeoutMs, ContinuousClock.now >= deadline else { return }
        cancel(FlowTimeoutError(timeoutMs: timeoutMs))
    }

    /// acpx's `drain`: every piece of owned work waited for, and what failed that is not
    /// the reason the attempt was cancelled for.
    private func drain() async -> [Error] {
        var errors: [Error] = []
        while true {
            let outstanding = lock.withLock { pending }
            if outstanding.isEmpty { break }
            for (id, outcome) in outstanding {
                if let error = await outcome.value, !isReason(error) { errors.append(error) }
                _ = lock.withLock { pending.removeValue(forKey: id) }
            }
        }
        let failures = lock.withLock { () -> [Error] in
            defer { cleanupFailures.removeAll() }
            return cleanupFailures
        }
        return errors + failures
    }

    private func isReason(_ error: Error) -> Bool {
        guard let reason = abortReason else { return false }
        return "\(error)" == "\(reason)" && type(of: error) == type(of: reason)
    }

    /// acpx's `trackCancellation`: run the cancellation as owned work, its failure kept.
    private func track(_ cancel: @escaping @Sendable (String) async throws -> Void) {
        let terminationSignal = self.terminationSignal
        let id = UUID()
        let outcome = Task<Error?, Never> { [weak self] in
            do {
                try await cancel(terminationSignal)
            } catch {
                self?.lock.withLock { self?.cleanupFailures.append(error) }
            }
            return nil
        }
        lock.withLock { pending[id] = outcome }
        Task { [weak self] in
            _ = await outcome.value
            _ = self?.lock.withLock { self?.pending.removeValue(forKey: id) }
        }
    }

    private func cleanupError(_ errors: [Error]) -> Error {
        var failures: [Error] = []
        if let reason = abortReason { failures.append(reason) }
        failures += errors
        return FlowAttemptCleanupError(errors: failures)
    }
}

extension Duration {
    static func milliseconds(_ value: Double) -> Duration {
        .nanoseconds(Int64(min(value * 1_000_000, Double(Int64.max))))
    }
}

/// A continuation resumed with the first result given it; later ones are dropped.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func settle(_ result: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
