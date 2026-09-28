import Foundation
import SwiftACP

/// The guard beside a session's ownership marker: fs-safe 0.18.2's file lock as acpx 0.19.3
/// takes it (`tryAcquireGuard`, `turn-ownership.ts`), file for file.
///
/// `<marker>.guard` is created only when absent and holds the owner and a token of this
/// acquisition's own: `JSON.stringify(owner.payload, null, 2)`, a newline, eight tabs and 128
/// tabs or spaces spelling 16 random bytes, a newline. It is let go by taking it away while it
/// still holds exactly that. One whose owner is gone (``AcpxLockOwner/hasExited(_:)``) is
/// taken away under `<guard>.reclaim`, a directory whose presence tells every other taker a
/// reclaim is going on. A try gives up after 15 ms or 8 waits of a millisecond, as acpx asks
/// fs-safe to; the ownership then tries again.
final class OwnershipGuard: @unchecked Sendable {
    /// acpx's `timeoutMs` for the guard.
    static let timeout: Duration = .milliseconds(15)
    /// acpx's `retry.retries`.
    static let retries = 8
    /// fs-safe's `MAX_LOCK_PAYLOAD_BYTES`: a guard larger is not read.
    static let maxBytes = 1024 * 1024

    let path: String
    /// What was written, token and all: the guard is ours while it holds exactly this.
    private let raw: String
    /// Kept open while held, as fs-safe keeps it.
    private var descriptor: Int32

    private init(path: String, raw: String, descriptor: Int32) {
        self.path = path
        self.raw = raw
        self.descriptor = descriptor
    }

    /// Take the guard of `marker` for `owner`, or `nil` when another holds it past the try's
    /// bounds (fs-safe's `file_lock_timeout`, which acpx takes as "not now").
    static func tryAcquire(_ marker: String, owner: AcpxLockOwner) throws -> OwnershipGuard? {
        var attempt = Attempt(path: marker + ".guard")
        defer { attempt.letReclaimGo() }
        while true {
            if !attempt.holdsReclaim, try exists(attempt.reclaim) {
                // Another is taking a guard back.
                guard attempt.waitForRetry() else { return nil }
                continue
            }
            let raw = WireJSON.object(owner.payload).stringified(indent: 2) + "\n" + token() + "\n"
            if let descriptor = try create(attempt.path, raw) {
                attempt.letReclaimGo()
                return OwnershipGuard(path: attempt.path, raw: raw, descriptor: descriptor)
            }
            if attempt.holdsReclaim {
                attempt.letReclaimGo()
                guard attempt.waitForRetry() else { return nil }
                continue
            }
            switch try reclaimIfStale(&attempt, marker: marker) {
            case .removed:
                continue
            case .wait:
                guard attempt.waitForRetry() else { return nil }
            }
        }
    }

    /// Whether the guard still holds what this acquisition wrote (fs-safe's `verifyStillHeld`).
    func verifyStillHeld() -> Bool {
        Self.snapshot(path)?.raw == raw
    }

    /// Let the guard go: closed, and taken away only while it still holds what was written.
    func release() throws {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        guard verifyStillHeld() else { return }
        if unlink(path) != 0, errno != ENOENT { throw POSIXError.current("unlink") }
    }

    // MARK: - Taking one

    /// One acquisition's bounds and its hold on `<guard>.reclaim`.
    struct Attempt {
        let path: String
        var reclaim: String { path + ".reclaim" }
        var holdsReclaim = false
        private let started = ContinuousClock.now
        private var waits = 0

        init(path: String) {
            self.path = path
        }

        /// Wait a millisecond before the next try, or `false` once the bounds are spent
        /// (fs-safe's `sidecarLockRetryDelay`).
        mutating func waitForRetry() -> Bool {
            let elapsed = ContinuousClock.now - started
            guard elapsed < OwnershipGuard.timeout, waits < OwnershipGuard.retries else { return false }
            waits += 1
            let remaining = OwnershipGuard.timeout - elapsed
            let delay = min(Duration.milliseconds(1), remaining)
            usleep(UInt32(delay.components.attoseconds / 1_000_000_000_000))
            return true
        }

        /// Give `<guard>.reclaim` up, when held.
        mutating func letReclaimGo() {
            guard holdsReclaim else { return }
            rmdir(reclaim)
            holdsReclaim = false
        }
    }

    enum Reclaim {
        /// The stale guard is gone: try again at once.
        case removed
        /// Not now: it is held, changed meanwhile, or another is reclaiming it.
        case wait
    }

    /// Take the guard away if its owner is gone, as fs-safe's `handleStaleSidecarAdmission`
    /// does for acpx: asked, the guard read again unchanged, `<guard>.reclaim` made, asked
    /// afresh, and read again unchanged just before it goes.
    private static func reclaimIfStale(_ attempt: inout Attempt, marker: String) throws -> Reclaim {
        guard let observed = try readSnapshot(attempt.path) else { return .wait }
        let payload = WireJSON(parsing: observed.raw)
        let owner: WireJSON? = if case .object? = payload { payload } else { nil }
        guard AcpxLockOwner.hasExited(owner), try readSnapshot(attempt.path) == observed else { return .wait }
        guard mkdir(attempt.reclaim, 0o777) == 0 else {
            if errno == EEXIST { return .wait }
            throw POSIXError.current("mkdir")
        }
        attempt.holdsReclaim = true
        guard try readSnapshot(attempt.path) == observed else { return .wait }
        guard AcpxLockOwner.hasExited(owner) else {
            attempt.letReclaimGo()
            throw SessionOwnershipError("file lock stale for \(marker)")
        }
        guard try readSnapshot(attempt.path) == observed else { return .wait }
        guard unlink(attempt.path) == 0 else {
            if errno == ENOENT { return .wait }
            throw POSIXError.current("unlink")
        }
        return .removed
    }

    /// Create the guard holding `raw`, only when absent: its descriptor, or `nil` when one is
    /// there already.
    private static func create(_ path: String, _ raw: String) throws -> Int32? {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { return nil }
            throw POSIXError.current("open")
        }
        fchmod(descriptor, 0o600)
        let bytes = Array(raw.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else {
                let error = POSIXError.current("write")
                close(descriptor)
                unlink(path)
                throw error
            }
            written += count
        }
        return descriptor
    }

    /// fs-safe's ownership token: eight tabs, then 16 random bytes, bit by bit from the top,
    /// a tab for 1 and a space for 0.
    private static func token() -> String {
        var token = String(repeating: "\t", count: 8)
        for _ in 0..<16 {
            let byte = UInt8.random(in: 0...255)
            for bit in (0..<8).reversed() { token.append(byte & (1 << bit) != 0 ? "\t" : " ") }
        }
        return token
    }

    // MARK: - Reading one

    /// Whether anything is at `path`.
    private static func exists(_ path: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError.current("lstat")
    }

    /// A guard as read: the file it was, and what it held.
    struct Snapshot: Equatable {
        var device: dev_t
        var inode: ino_t
        var raw: String
    }

    /// The guard at `path` as fs-safe reads one to judge it: `nil` when it is gone or was
    /// replaced while read. Throws for one that is not a regular file.
    static func readSnapshot(_ path: String) throws -> Snapshot? {
        var before = stat()
        guard lstat(path, &before) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError.current("lstat")
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw SessionOwnershipError("sidecar lock is not a regular file: \(path)")
        }
        return snapshot(path).flatMap { $0.device == before.st_dev && $0.inode == before.st_ino ? $0 : nil }
    }

    /// The file at `path` read through one descriptor, when it stays the same file throughout.
    private static func snapshot(_ path: String) -> Snapshot? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else { return nil }
        var bytes = [UInt8](repeating: 0, count: maxBytes + 1)
        var total = 0
        while total < bytes.count {
            let count = bytes[total...].withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            total += count
        }
        guard total <= maxBytes else { return nil }
        var after = stat()
        guard lstat(path, &after) == 0, after.st_dev == opened.st_dev, after.st_ino == opened.st_ino else {
            return nil
        }
        return Snapshot(
            device: opened.st_dev, inode: opened.st_ino, raw: String(decoding: bytes[0..<total], as: UTF8.self))
    }
}
