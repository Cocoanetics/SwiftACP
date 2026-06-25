import Foundation

/// Boot-time singleton guard for `acpxd`: at most one daemon may hold
/// `~/.acpx/acpxd.lock` at a time, so concurrent `acpx` cold-starts can't leave two
/// managers fighting over the same live sessions and records.
///
/// The lock is acquired by atomically creating the file (`O_EXCL`, via
/// `Data.write(options: .withoutOverwriting)`) carrying the holder's pid. A lock
/// left behind by a process that's no longer alive is treated as stale and taken
/// over; one held by a *live* pid refuses acquisition (the losing daemon exits).
/// The owner removes the lock on graceful shutdown; a hard crash leaves a stale
/// lock that the next daemon reclaims via the pid-liveness check.
public struct DaemonLock: Sendable {
    /// The persisted lock contents.
    public struct Holder: Codable, Sendable {
        public var pid: Int32
        /// The daemon's bound TCP port, recorded once it's listening so clients can
        /// connect directly. Nil until then, or for an older lock without it.
        public var port: Int?
        public var startedAt: String

        public init(pid: Int32, port: Int? = nil, startedAt: String) {
            self.pid = pid
            self.port = port
            self.startedAt = startedAt
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
        if DaemonLock.isProcessAlive(holder.pid) { return false }
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
        let data = try JSONEncoder().encode(Holder(pid: pid, startedAt: nowISO()))
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

    /// Whether `pid` names a live process. `kill(pid, 0)` succeeds for a signalable
    /// process and fails with `EPERM` for one owned by another user (still alive).
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
