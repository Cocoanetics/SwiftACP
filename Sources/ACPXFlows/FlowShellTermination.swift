import Foundation
import SwiftACP

// Split from `FlowShellProcess.swift` to keep that file inside the 500-line limit.

/// acpx's `createShellTermination`: what stops a command's tree — at its deadline, when
/// its attempt is cancelled, or for an owner — once, then lets it go. While an owner keeps
/// it, a command that closed with processes left in its group stays kept until they are
/// gone, so an interrupt still reaches them.
///
/// As acpx's `cancel` does, a stop marks the command cancelled at once — and timed out, at
/// its deadline — on whatever thread asks for it; only the stopping waits for the
/// cooperative pool, and a command that exits meanwhile still reads as stopped. The
/// deadline fires on a queue of its own, as Node's timer fires on its event loop: on the
/// pool, a busy machine held it until after the command had exited.
final class FlowShellTermination: @unchecked Sendable {
    /// For tests: the cooperative pool has no thread free for the command's stop until its
    /// result is in — a stop begun waits for ``dispose()`` — as on a busy machine.
    @TaskLocal static var poolIsBusy = false
    /// For tests: how long after its deadline the command's timer fires, as on a machine too
    /// busy to run it on time.
    @TaskLocal static var timerIsLateBy: Duration = .zero
    /// For tests: the task awaiting the command's result gets to ``dispose()`` only this long
    /// past the command's deadline, as on a pool too busy to resume it before the timer fires.
    @TaskLocal static var disposeIsLateBy: Duration?
    /// For tests: the exit thread takes this long to take the exit in past its first step, as a
    /// thread a busy machine does not run.
    @TaskLocal static var exitIsTakenInLateBy: Duration?

    /// Where deadlines fire.
    private static let deadlines = DispatchQueue(label: "acpx.flow.shell.deadline")

    /// The command's process, the root of the tree a stop ends.
    private let pid: pid_t
    private let closed: FlowShellEvent
    private let onCleanupFailure: @Sendable (Error) -> Void
    /// The attempt the command runs for: its own deadline, when no later than the command's
    /// and passed as well, comes first — acpx's timer for it, set first, fires first.
    private let attempt: FlowAttempt?
    /// When the command's deadline passes.
    private let deadlineAt: ContinuousClock.Instant?
    /// Fired by ``dispose()``, what a stop waits for while ``poolIsBusy``.
    private let busyPool: FlowShellEvent?
    private let lock = NSLock()
    private var stopping: Task<Void, Error>?
    private var timedOutFlag = false
    private var cancelledFlag = false
    private var released = false
    private var deadline: DispatchSourceTimer?
    private var monitor: Task<Void, Never>?
    private var unregister: (@Sendable () -> Void)?
    private var removeAbortListener: (() -> Void)?
    private var hasOwner = false

    init(
        pid: pid_t, closed: FlowShellEvent, timeoutMs: Double?, control: FlowShellControl,
        onCleanupFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.pid = pid
        self.closed = closed
        self.onCleanupFailure = onCleanupFailure
        attempt = control.attempt
        let delay = timeoutMs.flatMap(FlowTimer.duration(milliseconds:))
        deadlineAt = delay.map { ContinuousClock.now + $0 }
        busyPool = Self.poolIsBusy ? FlowShellEvent() : nil
        if let attempt = control.attempt {
            let listening = attempt.addAbortListener { [self] _ in begin(attempt.terminationSignal) }
            if let listening {
                removeAbortListener = listening
            } else {
                begin(attempt.terminationSignal)
            }
        }
        if let delay {
            let fires = delay + Self.timerIsLateBy
            lock.withLock {
                guard stopping == nil, !released else { return }
                let timer = DispatchSource.makeTimerSource(queue: Self.deadlines)
                timer.setEventHandler { [weak self] in self?.deadlinePassed() }
                timer.schedule(deadline: .now() + .nanoseconds(Int(fires / .nanoseconds(1))))
                deadline = timer
                timer.resume()
            }
        }
        if let registerOwner = control.registerOwner {
            hasOwner = true
            unregister = registerOwner(FlowShellOwner(
                cancel: { [self] signal in try await cancel(signal) }, release: { [self] in release() }))
        }
    }

    deinit {
        deadline?.cancel()
    }

    var timedOut: Bool { lock.withLock { timedOutFlag } }
    var cancelled: Bool { lock.withLock { cancelledFlag } }
    /// acpx's `cancelled()` and `timedOut()`, read together: whether a stop has begun, and
    /// whether for the deadline.
    var stopped: (cancelled: Bool, timedOut: Bool) { lock.withLock { (cancelledFlag, timedOutFlag) } }

    /// Stop the tree with `signal`, or wait for the stop under way.
    func cancel(_ signal: String) async throws {
        try await lock.withLock { stopTask(signal) }?.value
    }

    /// acpx's `cancel` without waiting for it: the stop begun with `signal`, unless one is
    /// under way.
    private func begin(_ signal: String) {
        _ = lock.withLock { stopTask(signal) }
    }

    /// acpx's deadline: unless it was cleared, the command timed out, and is stopped. An
    /// attempt past a deadline of its own no later than this one — its timer on the
    /// cooperative pool, late on a busy machine — times out first, and its stop clears this
    /// deadline. An earlier deadline of the command's stays its own, however late it fires.
    private func deadlinePassed() {
        if let attempt, let attemptDeadline = attempt.deadline, let deadlineAt, attemptDeadline <= deadlineAt {
            attempt.checkDeadline()
        }
        lock.withLock {
            guard deadline != nil else { return }
            timedOutFlag = true
            _ = stopTask("SIGTERM")
        }
    }

    /// The stop under way, or one begun with `signal` — none once let go. Called under the
    /// lock.
    private func stopTask(_ signal: String) -> Task<Void, Error>? {
        if let stopping { return stopping }
        guard !released else { return nil }
        clearDeadline()
        cancelledFlag = true
        let number = FlowShellSignals.number(signal)
        let (pid, closed, onCleanupFailure) = (self.pid, self.closed, self.onCleanupFailure)
        let task = Task { [self] in
            defer { release() }
            await busyPool?.wait()
            do {
                try await FlowShellTree.stop(pid, signal: number, closed: closed)
            } catch {
                onCleanupFailure(error)
                throw error
            }
        }
        stopping = task
        return task
    }

    /// The command's result is in: its deadline goes at once, as acpx's goes before its timer
    /// can fire — `dispose` runs in the microtasks that follow the result, and here it waits for
    /// the cooperative pool while the deadline fires on a queue of its own (#220 review). A stop
    /// begun before stays under way.
    func resultIsIn() {
        lock.withLock { clearDeadline() }
    }

    /// acpx's `clearDeadline`. Called under the lock.
    private func clearDeadline() {
        deadline?.cancel()
        deadline = nil
    }

    /// The command closed: kept by an owner, it stays kept while its group has processes.
    func handleClose() {
        let start: Bool = lock.withLock { hasOwner && !released && stopping == nil }
        guard start else { return }
        let watching = Task { [self] in
            while !Task.isCancelled {
                let idle = lock.withLock { stopping == nil }
                if idle, !FlowShellTree.hasProcesses(pid) {
                    release()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        lock.withLock { monitor = watching }
    }

    /// acpx's `dispose`: no deadline any more, the stop under way waited for, and — kept
    /// by no one — let go.
    func dispose() async throws {
        if let late = Self.disposeIsLateBy, let deadlineAt { try? await Task.sleep(until: deadlineAt + late) }
        let task: Task<Void, Error>? = lock.withLock {
            clearDeadline()
            return stopping
        }
        busyPool?.fire()
        defer { if !hasOwner { release() } }
        try await task?.value
    }

    /// acpx's `release`.
    func release() {
        let (listening, unregistering): ((() -> Void)?, (@Sendable () -> Void)?) = lock.withLock {
            guard !released else { return (nil, nil) }
            released = true
            clearDeadline()
            monitor?.cancel()
            defer {
                removeAbortListener = nil
                unregister = nil
            }
            return (removeAbortListener, unregister)
        }
        listening?()
        unregistering?()
    }
}
