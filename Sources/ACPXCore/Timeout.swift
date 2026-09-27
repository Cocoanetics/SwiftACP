import Foundation

/// acpx's `TimeoutError`: a step ran past `--timeout`. It reports as `TIMEOUT` (exit 3),
/// and a prompt that ran out of time is never retried.
public struct TimeoutError: Error, OutputErrorMeta, LocalizedError, Equatable {
    public let milliseconds: Int

    public init(milliseconds: Int) {
        self.milliseconds = milliseconds
    }

    /// `Timed out after <ms>ms`, in acpx's words.
    public var errorDescription: String? { "Timed out after \(milliseconds)ms" }
    public var outputCode: String? { "TIMEOUT" }
    public var detailCode: String? { nil }
    public var origin: String? { nil }
}

/// acpx's `withTimeout`: what `operation` returns, unless `milliseconds` pass first —
/// then ``TimeoutError`` is thrown and `operation` is cancelled. A deadline that is `nil`
/// or not positive is no deadline.
///
/// Like acpx's `Promise.race`, the deadline does not wait for the cancelled operation to
/// wind down. A prompt can be held by a request of the agent's that no cancel reaches —
/// a question put to the terminal — and it would hold the deadline with it. What the
/// operation started is the caller's to put down, as acpx closes its client.
public func withTimeout<T: Sendable>(
    milliseconds: Int?, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let milliseconds, milliseconds > 0 else { return try await operation() }
    let race = DeadlineRace<T>()
    let pass: @Sendable () -> Void = { race.settle(.failure(TimeoutError(milliseconds: milliseconds))) }
    // A test's source can pass the deadline too (``DeadlineSource``). It waits there from
    // before the operation starts, so nothing the operation brings about fires it first.
    let source = DeadlineSource.current
    let waiting = source?.add(pass)
    // Unstructured, so that the deadline need not wait for it (see above).
    let work = Task {
        do {
            race.settle(.success(try await operation()))
        } catch {
            race.settle(.failure(error))
        }
    }
    let deadline = Task {
        try await Task.sleep(nanoseconds: nanoseconds(milliseconds))
        pass()
    }
    defer {
        deadline.cancel()
        work.cancel()
        if let source, let waiting { source.remove(waiting) }
    }
    return try await withTaskCancellationHandler {
        try await race.outcome()
    } onCancel: {
        race.settle(.failure(CancellationError()))
    }
}

/// Stands in for the passing of time in a test: ``fire()`` passes each deadline of
/// ``withTimeout(milliseconds:_:)`` waiting then, as if its time were up. Those set later
/// keep their own time. A test can so end a step at an event of its choosing — the agent
/// getting its prompt — however long the steps before it took on a busy machine.
final class DeadlineSource: @unchecked Sendable {
    /// The source a run under test has its deadlines passed from, as well as by their time.
    @TaskLocal static var current: DeadlineSource?

    private let lock = NSLock()
    private var waiting: [Int: @Sendable () -> Void] = [:]
    private var nextId = 0

    func fire() {
        let due: [@Sendable () -> Void] = lock.withLock {
            defer { waiting = [:] }
            return Array(waiting.values)
        }
        for pass in due { pass() }
    }

    fileprivate func add(_ pass: @escaping @Sendable () -> Void) -> Int {
        lock.withLock {
            defer { nextId += 1 }
            waiting[nextId] = pass
            return nextId
        }
    }

    fileprivate func remove(_ id: Int) {
        _ = lock.withLock { waiting.removeValue(forKey: id) }
    }
}

/// `milliseconds` in nanoseconds — the longest sleep there is, for more than fits.
private func nanoseconds(_ milliseconds: Int) -> UInt64 {
    let (product, overflow) = UInt64(milliseconds).multipliedReportingOverflow(by: 1_000_000)
    return overflow ? .max : product
}

/// ``withTimeout(milliseconds:_:)`` for an operation that starts what its caller would
/// have to put down — an agent's launch: at the deadline the operation is cancelled and
/// waited for, as it puts down what it started on its way out (acpx closes the client it
/// was starting), and what it came up with just then goes to `discard`.
public func withTimeout<T: Sendable>(
    milliseconds: Int?, _ operation: @escaping @Sendable () async throws -> T,
    discardingLate discard: @escaping @Sendable (T) async -> Void
) async throws -> T {
    let running = Task { try await operation() }
    do {
        return try await withTimeout(milliseconds: milliseconds) {
            try await withTaskCancellationHandler {
                try await running.value
            } onCancel: {
                running.cancel()
            }
        }
    } catch {
        running.cancel()
        if let late = try? await running.value { await discard(late) }
        throw error
    }
}

/// The first of an operation's result and its deadline, handed to whoever waits for it.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    /// Settle the race with `result`, unless it is settled already.
    func settle(_ result: Result<T, Error>) {
        let waiter: CheckedContinuation<T, Error>? = lock.withLock {
            guard settled == nil else { return nil }
            settled = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }

    func outcome() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<T, Error>? = lock.withLock {
                if let settled { return settled }
                waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
}
