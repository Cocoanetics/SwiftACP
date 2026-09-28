import ACPXCore
import Foundation
import SwiftACP

/// acpxd as the CLI starts it, watched as acpx watches the queue owner it spawns
/// (`spawnQueueOwnerProcess`): the end of what it writes to stderr while it starts —
/// its last 4,000 bytes — and how it ended, if it has, so that a daemon that dies while
/// starting is reported at once, and why.
final class DaemonStartup: @unchecked Sendable {
    /// acpx's `QUEUE_OWNER_STARTUP_STDERR_MAX_BYTES`.
    static let stderrLimit = 4_000

    /// For tests: the poll's clock never comes round, as on a machine too busy to run it —
    /// only the daemon's failure, or a call-off, ends a wait for it (``pause(for:)``).
    @TaskLocal static var pollIsHeld = false

    /// Where the poll's clock runs: on a queue of its own, so that a wait that runs its
    /// time takes one turn on the cooperative pool to end, as `Task.sleep` does — not two.
    private static let clock = DispatchQueue(label: "acpx.daemon.startup.poll")

    private let lock = NSLock()
    private var tail = Data()
    private var capturing = true
    private var stderrClosed = false
    private var ended: (reason: Process.TerminationReason, status: Int32)?
    /// What ends each wait for it (``pause(for:)``) once it has failed.
    private var wakes: [UUID: @Sendable () -> Void] = [:]
    private let process = Process()
    private let stderr = Pipe()

    private init() {}

    /// Start `executable`, its stdin and stdout on `/dev/null` and its stderr read here.
    static func launch(_ executable: String) throws -> DaemonStartup {
        let startup = DaemonStartup()
        let process = startup.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = startup.stderr
        process.environment = ProcessInfo.processInfo.environment
        process.qualityOfService = .utility
        startup.stderr.fileHandleForReading.readabilityHandler = { handle in
            startup.read(handle.availableData, from: handle)
        }
        process.terminationHandler = { process in
            startup.end(process.terminationReason, process.terminationStatus)
        }
        try process.run()
        return startup
    }

    /// Keep no more of what it writes, but go on reading it — acpx's
    /// `stopStartupCapture` — so that a daemon writing on finds its stderr open for as
    /// long as this process runs.
    func stopCapture() {
        lock.withLock { capturing = false }
    }

    private func read(_ data: Data, from handle: FileHandle) {
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            wake(lock.withLock {
                stderrClosed = true
                return wakesOnceFailed()
            })
            return
        }
        lock.withLock {
            guard capturing else { return }
            tail.append(data)
            if tail.count > Self.stderrLimit { tail = Data(tail.suffix(Self.stderrLimit)) }
        }
    }

    private func end(_ reason: Process.TerminationReason, _ status: Int32) {
        wake(lock.withLock {
            ended = (reason, status)
            return wakesOnceFailed()
        })
    }

    /// How it ended, once it has and its stderr is read to the end — Node's `close`,
    /// which acpx waits for so the report has its last words: its exit code, or `nil`
    /// and the signal that ended it.
    var exit: (code: Int32?, signal: String?)? {
        lock.withLock { exitState }
    }

    /// ``exit``, read under the lock.
    private var exitState: (code: Int32?, signal: String?)? {
        guard let ended, stderrClosed else { return nil }
        if ended.reason == .uncaughtSignal {
            return (nil, TerminalExitStatus.signalName(ended.status) ?? String(ended.status))
        }
        return (ended.status, nil)
    }

    /// Whether it failed to start: acpx's `queueOwnerExitIsFatal` — it ended, other than
    /// with code 0, which a daemon that finds another already running ends with.
    var failed: Bool {
        lock.withLock { hasFailed }
    }

    /// ``failed``, read under the lock.
    private var hasFailed: Bool {
        exitState.map { $0.code != 0 || $0.signal != nil } ?? false
    }

    /// Wait `interval` before the next try to reach it, as acpx waits between its tries —
    /// or only until it fails (``failed``), which ends the wait from the thread that saw
    /// it end: no wait of the poll's stands between a daemon's failure and its report.
    /// One that ends cleanly is waited past. Called off, it throws.
    func pause(for interval: Duration) async throws {
        try Task.checkCancellation()
        let race = DeadlineRace<Void>()
        let id = UUID()
        let failedAlready: Bool = lock.withLock {
            if hasFailed { return true }
            wakes[id] = { race.settle(.success(())) }
            return false
        }
        if failedAlready { return }
        defer { _ = lock.withLock { wakes.removeValue(forKey: id) } }
        let timer = Self.pollIsHeld ? nil : Self.timer(after: interval) { race.settle(.success(())) }
        defer { timer?.cancel() }
        try await withTaskCancellationHandler {
            try await race.outcome()
        } onCancel: {
            race.settle(.failure(CancellationError()))
        }
    }

    /// Whether it wrote anything on stderr while it started.
    var wroteToStderr: Bool {
        lock.withLock { !tail.isEmpty }
    }

    /// acpx's `formatQueueOwnerStartupFailure`, for acpxd: how it ended, if it has, and
    /// what it wrote on stderr, if anything.
    var failureMessage: String {
        var parts = ["acpxd failed to start"]
        if let exit {
            let code = exit.code.map(String.init) ?? "null"
            let signal = exit.signal.map { ", signal \($0)" } ?? ""
            parts.append("exited with code \(code)\(signal) before binding its socket")
        }
        let written = String(decoding: lock.withLock { tail }, as: UTF8.self).javaScriptTrimmed
        if !written.isEmpty { parts.append("stderr:\n\(written)") }
        return parts.joined(separator: ": ")
    }

    /// Once it has failed, what waits for it, to be woken — each once. Called under the lock.
    private func wakesOnceFailed() -> [@Sendable () -> Void] {
        guard hasFailed else { return [] }
        defer { wakes.removeAll() }
        return Array(wakes.values)
    }

    private func wake(_ waiting: [@Sendable () -> Void]) {
        for wake in waiting { wake() }
    }

    /// A timer on ``clock`` that calls `fire` once `interval` has passed.
    private static func timer(
        after interval: Duration, _ fire: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: clock)
        timer.setEventHandler(handler: fire)
        timer.schedule(deadline: .now() + .nanoseconds(Int(interval / .nanoseconds(1))))
        timer.resume()
        return timer
    }
}
