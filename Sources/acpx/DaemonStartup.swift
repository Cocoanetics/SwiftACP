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

    private let lock = NSLock()
    private var tail = Data()
    private var capturing = true
    private var stderrClosed = false
    private var ended: (reason: Process.TerminationReason, status: Int32)?
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
            startup.lock.withLock { startup.ended = (process.terminationReason, process.terminationStatus) }
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
            lock.withLock { stderrClosed = true }
            return
        }
        lock.withLock {
            guard capturing else { return }
            tail.append(data)
            if tail.count > Self.stderrLimit { tail = Data(tail.suffix(Self.stderrLimit)) }
        }
    }

    /// How it ended, once it has and its stderr is read to the end — Node's `close`,
    /// which acpx waits for so the report has its last words: its exit code, or `nil`
    /// and the signal that ended it.
    var exit: (code: Int32?, signal: String?)? {
        lock.withLock {
            guard let ended, stderrClosed else { return nil }
            if ended.reason == .uncaughtSignal {
                return (nil, TerminalExitStatus.signalName(ended.status) ?? String(ended.status))
            }
            return (ended.status, nil)
        }
    }

    /// Whether it failed to start: acpx's `queueOwnerExitIsFatal` — it ended, other than
    /// with code 0, which a daemon that finds another already running ends with.
    var failed: Bool {
        exit.map { $0.code != 0 || $0.signal != nil } ?? false
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
}
