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

/// A flow's timers, held to Node's: `setTimeout` runs a delay above 2,147,483,647 ms — or
/// one that is no finite number — after 1 ms instead, which timed a node or command out
/// at once (openclaw/acpx#812). acpx 0.19.4 refuses such a deadline before it is set.
enum FlowTimer {
    /// acpx's `MAX_TIMER_DELAY_MS`.
    static let maxDelayMs = Double(JavaScriptNumber.maxTimerDelayMs)

    /// acpx's `resolveFlowTimeoutMs` (`src/flows/timeout.ts`): no deadline for none given,
    /// or for nothing positive; the deadline as given, within the limit; else the
    /// `TypeError` acpx throws, for a node's and a command's deadline alike.
    static func resolveTimeoutMs(_ timeoutMs: Double?) throws -> Double? {
        guard let timeoutMs else { return nil }
        guard timeoutMs.isFinite, timeoutMs <= maxDelayMs else { throw FlowTimerLimitError() }
        return timeoutMs > 0 ? timeoutMs : nil
    }

    /// A delay as a `Duration`: `nil` for one past the limit. A deadline never is, once
    /// resolved; a `heartbeatMs` past it — which acpx 0.19.4 left as it was, so Node's
    /// `setInterval` runs it every 1 ms — is no heartbeat here (openclaw/acpx#812).
    static func duration(milliseconds: Double) -> Duration? {
        guard milliseconds.isFinite, milliseconds <= maxDelayMs else { return nil }
        return .nanoseconds(Int64(max(0, milliseconds) * 1_000_000))
    }
}

/// acpx's `TypeError` for a deadline Node's timer cannot hold (openclaw/acpx#812).
struct FlowTimerLimitError: Error, LocalizedError, Equatable {
    var errorDescription: String? {
        "timeoutMs must be a finite number no greater than \(JavaScriptNumber.maxTimerDelayMs)"
    }
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

/// Stands in for the passing of time in a test: ``fire()`` passes the deadline of each
/// attempt made while it was ``FlowAttempt/deadlines``, as if its time were up. A test can so
/// end a step at an event of its choosing — its command ready — however long the steps
/// before it took on a busy machine.
final class FlowDeadlines: @unchecked Sendable {
    private let lock = NSLock()
    private var passes: [@Sendable () -> Void] = []

    func fire() {
        let due = lock.withLock {
            defer { passes = [] }
            return passes
        }
        for pass in due { pass() }
    }

    fileprivate func add(_ pass: @escaping @Sendable () -> Void) {
        lock.withLock { passes.append(pass) }
    }
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
    /// The source a test passes attempts' deadlines from, as well as by their time.
    @TaskLocal static var deadlines: FlowDeadlines?
    /// For tests: an attempt's timer never fires, as on a busy machine whose cooperative
    /// pool runs it only after the step is over; only ``checkDeadline()`` times it out.
    @TaskLocal static var timerIsLate = false
    let nodeId: String
    let attemptId: String
    let startedAt: String

    private let timeoutMs: Double?
    /// When the attempt times out, if it has a deadline.
    let deadline: ContinuousClock.Instant?
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

    /// `timeoutMs` is the deadline as ``FlowTimer/resolveTimeoutMs(_:)`` gave it: within
    /// Node's timer limit, or none.
    init(nodeId: String, attemptId: String, startedAt: String, timeoutMs: Double?) {
        self.nodeId = nodeId
        self.attemptId = attemptId
        self.startedAt = startedAt
        let delay = timeoutMs.flatMap { $0 > 0 ? FlowTimer.duration(milliseconds: $0) : nil }
        if let timeoutMs, timeoutMs > 0 {
            self.timeoutMs = timeoutMs
            deadline = delay.map { ContinuousClock.now + $0 }
        } else {
            self.timeoutMs = nil
            deadline = nil
        }
        if let timeoutMs = self.timeoutMs, let delay, !Self.timerIsLate {
            timer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.cancel(FlowTimeoutError(timeoutMs: timeoutMs))
            }
        }
        if let timeoutMs = self.timeoutMs {
            Self.deadlines?.add { [weak self] in self?.cancel(FlowTimeoutError(timeoutMs: timeoutMs)) }
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

    /// acpx's `signal.addEventListener("abort", …)`: `handler` hears the reason when the
    /// attempt is cancelled. Returns what takes it off again — or `nil`, adding nothing,
    /// when the attempt is cancelled already.
    func addAbortListener(_ handler: @escaping @Sendable (Error) -> Void) -> (() -> Void)? {
        let id = UUID()
        let added: Bool = lock.withLock {
            guard reason == nil else { return false }
            abortHandlers[id] = handler
            return true
        }
        guard added else { return nil }
        return { [weak self] in _ = self?.lock.withLock { self?.abortHandlers.removeValue(forKey: id) } }
    }

    /// acpx's `registerCancellation`: run at once if the attempt is not active.
    @discardableResult
    func registerCancellation(_ cancel: @escaping @Sendable (String) async throws -> Void) -> @Sendable () -> Void {
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
    func checkDeadline() {
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

/// A continuation resumed with the first result given it; later ones are dropped.
final class FirstResult<T: Sendable>: @unchecked Sendable {
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
