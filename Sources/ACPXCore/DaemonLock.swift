import Foundation
import SwiftACP

/// Boot-time singleton guard for `acpxd`: at most one daemon may hold
/// `~/.acpx/acpxd.lock` at a time, so concurrent `acpx` cold-starts can't leave two
/// managers fighting over the same live sessions and records.
///
/// The lock is acquired by atomically creating the file (`O_EXCL`, via
/// `Data.write(options: .withoutOverwriting)`) carrying the holder's pid and birth. A
/// lock whose holder is gone is treated as stale and taken over; one held by a live
/// holder refuses acquisition (the losing daemon exits). The owner removes the lock on
/// graceful shutdown; a hard crash leaves a stale lock that the next daemon reclaims —
/// even once another process has taken the dead holder's pid (``isHeld(_:)``).
public struct DaemonLock: Sendable {
    /// The persisted lock contents.
    public struct Holder: Codable, Sendable {
        public var pid: Int32
        /// The daemon's bound TCP port, recorded once it's listening so clients can
        /// connect directly. Nil until then, or for an older lock without it.
        public var port: Int?
        public var startedAt: String
        /// The holder's ``SwiftACP/ProcessBirth/identity(of:)``: a live pid with another
        /// birth is another process. Nil in a lock written before it was recorded.
        public var birth: String?

        public init(pid: Int32, port: Int? = nil, startedAt: String, birth: String? = nil) {
            self.pid = pid
            self.port = port
            self.startedAt = startedAt
            self.birth = birth
        }
    }

    private let url: URL
    /// This process's pid — written into the lock and checked before release.
    public let pid: Int32

    public init(url: URL = ACPXPaths.daemonLockPath) {
        self.url = url
        self.pid = getpid()
    }

    /// Atomically acquire the lock. Returns `true` if this process now owns it, or
    /// `false` if another *live* daemon already holds it (the caller should exit). A
    /// stale lock (holder pid not alive) is removed and acquisition retried once.
    @discardableResult
    public func acquire() throws -> Bool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if try create() { return true }
        // The lock exists. If it's unreadable/partial, assume a peer is mid-init and
        // back off rather than risk stealing a lock that's about to be live.
        guard let holder = currentHolder() else { return false }
        if DaemonLock.isHeld(holder) { return false }
        // Stale: the previous owner is gone. Reclaim it.
        try? FileManager.default.removeItem(at: url)
        return try create()
    }

    /// Release the lock, but only if this process still owns it — so a daemon that
    /// reclaimed a stale lock and then shut down can't delete a successor's lock.
    public func release() {
        guard let holder = currentHolder(), holder.pid == pid else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The current on-disk holder, or nil if the lock is absent/unreadable.
    public func currentHolder() -> Holder? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Holder.self, from: data)
    }

    /// Record the daemon's bound TCP port in the lock once the transport is
    /// listening, so clients connect directly (`127.0.0.1:port`) instead of via
    /// Bonjour discovery. No-op unless this process still owns the lock.
    public func update(port: Int) {
        guard var holder = currentHolder(), holder.pid == pid else { return }
        holder.port = port
        try? write(holder)
    }

    /// Create the lock file atomically, writing this process's holder record.
    /// Returns `false` if it already exists.
    private func create() throws -> Bool {
        let holder = Holder(pid: pid, startedAt: nowISO(), birth: ProcessBirth.identity(of: pid))
        let data = try JSONEncoder().encode(holder)
        do {
            try data.write(to: url, options: .withoutOverwriting)
            return true
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return false
        }
    }

    /// Overwrite the lock file with `holder` (the caller must own the lock).
    private func write(_ holder: Holder) throws {
        try JSONEncoder().encode(holder).write(to: url)
    }

    /// Whether `holder` still holds its lock: its pid names a live process, and that
    /// process is the one that wrote the lock, as acpx tells its owner by its birth
    /// (`observeProcessIncarnation`, 0.19.2) — a crashed daemon's pid may have been
    /// taken since. A birth that cannot be read is taken at its word, as acpx takes an
    /// `unknown` one. A lock from before births were recorded is judged by when it was
    /// written: a process that started after that cannot have written it.
    public static func isHeld(_ holder: Holder) -> Bool {
        guard isProcessAlive(holder.pid) else { return false }
        if let recorded = holder.birth {
            guard let current = ProcessBirth.identity(of: holder.pid) else { return true }
            return current == recorded
        }
        guard let started = ProcessBirth.date(of: holder.pid), let written = parseTimestamp(holder.startedAt) else {
            return true
        }
        // `startedAt` is written after the holder started, and to the millisecond.
        return started <= written.addingTimeInterval(1)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Whether `pid` names a live process. `kill(pid, 0)` succeeds for a signalable
    /// process and fails with `EPERM` for one owned by another user (still alive).
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
