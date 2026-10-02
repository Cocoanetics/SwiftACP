import CryptoKit
import Foundation
import SwiftACP

/// A session's ownership as acpx 0.19.3 takes one (`turn-ownership.ts`): a marker file,
/// published by hard link so it appears whole or not at all, beside fs-safe's guard lock
/// (``OwnershipGuard``), which is held for as long as the marker is. Either can outlive a
/// crash; both name their owner by pid and birth (``AcpxLockOwner``), so a marker or guard
/// whose owner is gone is taken back.
///
/// acpx takes it for an import (``importAdmission()``, `.import-admission.lock`) and for a
/// session's scope — its agent, directory and name (``scope(agentCommand:cwd:name:)``), the
/// marker acpx's `sessions ensure` takes — so of two imports, or an import and an ensure,
/// that would each find no session and make one, only one does. The same files as acpx's,
/// taken the same way, keep SwiftACP and acpx out of each other's way too.
public final class SessionOwnership: @unchecked Sendable {
    /// acpx's `LOCK_RETRY_MS`: the wait between two tries.
    static let retryMilliseconds: UInt32 = 15
    /// acpx's `INCOMPLETE_RESERVATION_GRACE_MS`: how long a marker that names no owner — one
    /// still being written — is left alone.
    static let incompleteReservationGrace: TimeInterval = 15

    private let path: String
    private let owner: AcpxLockOwner
    private var guardLock: OwnershipGuard?
    /// The marker as it was published: taken away only while it is still that one.
    private let observed: Snapshot
    private var settled = false
    /// Whether letting it go failed: the next try at its path in this process tries again
    /// first, as acpx settles a failed receipt.
    private var failed = false
    private let lock = NSLock()

    private init(path: String, owner: AcpxLockOwner, guardLock: OwnershipGuard, observed: Snapshot) {
        self.path = path
        self.owner = owner
        self.guardLock = guardLock
        self.observed = observed
    }

    /// acpx's `acquireSessionScope`: the marker `ensure%3A<key>.stream.lock` in the sessions
    /// directory, `key` the SHA-256 of `JSON.stringify([agentCommand, cwd, name])` — `cwd`
    /// absolute and `name` trimmed, `null` when it has nothing left.
    ///
    /// `agentCommand` is keyed as the current built-in command when it is an earlier built-in
    /// default (``BuiltInCommandMigration/canonicalAgentCommand(_:)``): the lookups made under
    /// the ownership match that command's whole scope (openclaw/acpx#838), so two ensures for
    /// one scope, one by the current command and one by an earlier default, would otherwise
    /// hold different ownerships, each find no session, and both make one. For the current
    /// command the marker is acpx's, file for file; for an earlier default it is not — acpx
    /// keys it on the raw command (openclaw/acpx#851).
    public static func scope(agentCommand: String, cwd: String, name: String?) throws -> SessionOwnership {
        try acquire(scopeMarker(agentCommand: agentCommand, cwd: cwd, name: name))
    }

    /// Where the marker of a scope's ownership is.
    static func scopeMarker(agentCommand: String, cwd: String, name: String?) -> URL {
        let command = BuiltInCommandMigration.canonicalAgentCommand(agentCommand)
        let trimmed = name.map { SessionRecordParser.javaScriptTrimmed(Array($0.utf16)) } ?? []
        let key = WireJSON.array([
            .text(command), .text(NodePath.resolve(cwd)), trimmed.isEmpty ? .null : .string(trimmed)
        ]).stringified
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return ACPXPaths.sessionStreamLockPath("ensure:\(digest)")
    }

    /// acpx's `acquireSessionImport`: `.import-admission.lock` in the sessions directory.
    public static func importAdmission() throws -> SessionOwnership {
        try acquire(ACPXPaths.sessionsDir.appendingPathComponent(".import-admission.lock"))
    }

    /// Take the ownership `requested` names, waiting while another holds it (acpx's
    /// `acquireSessionOwnership`): tried again every 15 ms, for as long as it takes.
    static func acquire(_ requested: URL) throws -> SessionOwnership {
        try FileManager.default.createDirectory(
            at: requested.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = canonical(requested)
        let owner = AcpxLockOwner.current
        let payload = markerPayload(for: owner)
        while true {
            if let held = try tryAcquire(path, payload: payload, owner: owner) { return held }
            waiting?(path)
            usleep(retryMilliseconds * 1000)
        }
    }

    /// `body`, run while this is held, and this let go after it — as acpx's `await using`
    /// lets an ownership go however its block ends. When `body` fails, its error is what
    /// comes out; otherwise one letting go failed with.
    public func holding<T>(_ body: () throws -> T) throws -> T {
        let result: T
        do {
            result = try body()
        } catch {
            try? release()
            throw error
        }
        try release()
        return result
    }

    /// `requested` with its directory's real path, as acpx keys an ownership.
    static func canonical(_ requested: URL) -> String {
        let directory = requested.deletingLastPathComponent().path
        return (realpath(directory) ?? directory) + "/" + requested.lastPathComponent
    }

    /// Let the ownership go: the marker taken away, if it is still the one published, under
    /// the guard — taken again if it was lost meanwhile — then the guard released (acpx's
    /// `disposeTurn`). Throws when the guard cannot be had to take the marker away.
    public func release() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        failed = true
        if let held = guardLock, !held.verifyStillHeld() {
            try? held.release()
            guardLock = nil
        }
        if guardLock == nil { guardLock = try OwnershipGuard.tryAcquire(path, owner: owner) }
        guard let held = guardLock else {
            throw SessionOwnershipError("Session turn cleanup is waiting for its guard: \(path)")
        }
        _ = try Self.removeObserved(path, observed)
        try held.release()
        guardLock = nil
        settled = true
        failed = false
        Self.localTurns.remove(path)
    }

    /// Whether letting it go failed, and should be tried again.
    fileprivate var releaseFailed: Bool { lock.withLock { failed } }

    // MARK: - Taking it

    /// Told the marker's path each time a try finds the ownership held, before waiting — for
    /// tests, which act while a taker waits.
    nonisolated(unsafe) static var waiting: (@Sendable (String) -> Void)?

    /// Paths this process holds or is taking, which it does not take again meanwhile (acpx's
    /// `localTurns`).
    private static let localTurns = LocalTurns()

    /// One try: the guard, then the marker published under it. `nil` when another holds
    /// either (acpx's `tryAcquireTurn`).
    static func tryAcquire(_ path: String, payload: String, owner: AcpxLockOwner) throws -> SessionOwnership? {
        switch localTurns.claim(path) {
        case .claimed:
            break
        case .held(let previous):
            // As acpx settles a receipt whose cleanup failed before its path is tried again.
            if let previous, previous.releaseFailed { try? previous.release() }
            return nil
        }
        let guardLock: OwnershipGuard
        do {
            guard let taken = try OwnershipGuard.tryAcquire(path, owner: owner) else {
                localTurns.remove(path)
                return nil
            }
            guardLock = taken
        } catch {
            localTurns.remove(path)
            throw error
        }
        do {
            guard try tryPublish(path, payload: payload) else {
                // Ours was never published: nothing of it to take away.
                try guardLock.release()
                localTurns.remove(path)
                return nil
            }
            guard let observed = try read(path), observed.payload == payload else {
                throw SessionOwnershipError("Session turn ownership changed before admission: \(path)")
            }
            let held = SessionOwnership(path: path, owner: owner, guardLock: guardLock, observed: observed)
            localTurns.register(held, at: path)
            return held
        } catch {
            // As acpx's `rejectAcquisition`: a marker of ours is taken away, the guard let go.
            if let current = try? read(path), current.payload == payload { _ = try? removeObserved(path, current) }
            try? guardLock.release()
            localTurns.remove(path)
            throw error
        }
    }

    /// Publish the marker, taking back one whose owner is gone first. `false` when another's
    /// stands (acpx's `tryPublishLock`).
    private static func tryPublish(_ path: String, payload: String) throws -> Bool {
        while true {
            if try publish(path, payload: payload) { return true }
            guard try recoverAbandoned(path) else { return false }
        }
    }

    /// Write the marker to a temporary file in a directory of its own beside it, and link it
    /// in place: it appears whole, and never over another (acpx's `publishLock`). `false`
    /// when a marker is already there.
    private static func publish(_ path: String, payload: String) throws -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        var template = Array("\(directory)/session-turn-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError.current("mkdtemp") }
        let temporaryDirectory = String(cString: made)
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let temporary = temporaryDirectory + "/lock"
        try writeExclusively(temporary, payload)
        if link(temporary, path) == 0 { return true }
        switch errno {
        case EEXIST:
            return false
        case EPERM, EXDEV, ENOTSUP, EOPNOTSUPP, ENOSYS:
            // A filesystem without hard links: written in place, as acpx falls back to
            // (fs-safe's `isHardlinkFallbackError`).
            do {
                try writeExclusively(path, payload)
                return true
            } catch let error as POSIXError where error.code == .EEXIST {
                return false
            }
        default:
            throw POSIXError.current("link")
        }
    }

    /// Take away a marker whose owner is gone: one that names a pid no process of that birth
    /// has, or one that names none — left half-written — after its grace (acpx's
    /// `recoverAbandonedLock`). `true` when it is gone.
    private static func recoverAbandoned(_ path: String) throws -> Bool {
        guard let observed = try read(path) else { return true }
        let payload = WireJSON(parsing: observed.payload)
        if AcpxLockOwner.pid(in: payload) != nil {
            // As acpx asks twice, the second time afresh, before taking a marker away.
            guard AcpxLockOwner.hasExited(payload), AcpxLockOwner.hasExited(payload) else { return false }
        } else if Date().timeIntervalSince(observed.modified) <= incompleteReservationGrace {
            return false
        }
        return try removeObserved(path, observed)
    }
}

extension SessionOwnership {
    /// A marker as read: what it says, and enough of its file to tell whether it changed since.
    struct Snapshot: Equatable {
        var payload: String
        var modifiedNanoseconds: Int64
        var size: Int64
        var modified: Date {
            Date(timeIntervalSince1970: Double(modifiedNanoseconds) / 1_000_000_000)
        }
    }

    /// The marker at `path`, or `nil` when there is none (acpx's `readLock`). Throws for one
    /// that is not a regular file.
    static func read(_ path: String) throws -> Snapshot? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError.current("lstat")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw SessionOwnershipError("Session turn lock is not a regular file: \(path)")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            if errno == ENOENT { return nil }
            throw POSIXError.current("read")
        }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return Snapshot(
            payload: String(decoding: data, as: UTF8.self), modifiedNanoseconds: modified, size: Int64(info.st_size))
    }

    /// Take the marker away only while it is still `observed` (acpx's `removeObservedLock`).
    /// `true` when it is gone.
    static func removeObserved(_ path: String, _ observed: Snapshot) throws -> Bool {
        guard let current = try read(path) else { return true }
        guard current == observed else { return false }
        if unlink(path) != 0, errno != ENOENT { throw POSIXError.current("unlink") }
        return true
    }

    /// The marker's text: the owner, and when it was taken, as acpx writes it —
    /// `JSON.stringify({...owner.payload, created_at}, null, 2)` and a newline, each birth
    /// in a process later than the last.
    static func markerPayload(for owner: AcpxLockOwner) -> String {
        let millisecond = createdAt.next()
        let date = Date(timeIntervalSince1970: Double(millisecond) / 1000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let members = owner.payload + [WireJSON.Member("created_at", .text(formatter.string(from: date)))]
        return WireJSON.object(members).stringified(indent: 2) + "\n"
    }

    /// acpx's `lastCreatedAt`: the millisecond of the last marker made here.
    private static let createdAt = CreatedAt()

    /// Create `path` holding `text`, only when it does not exist, readable by its owner alone.
    static func writeExclusively(_ path: String, _ text: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError.current("open") }
        defer { close(descriptor) }
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { throw POSIXError.current("write") }
            written += count
        }
    }
}

/// The paths this process holds, or is taking, with what holds each once it is taken.
private final class LocalTurns: @unchecked Sendable {
    enum Claim {
        case claimed
        /// Taken here already, or being taken (`nil`).
        case held(SessionOwnership?)
    }

    private var paths: [String: SessionOwnership?] = [:]
    private let lock = NSLock()

    /// `path` claimed for a try, unless this process holds or is taking it.
    func claim(_ path: String) -> Claim {
        lock.withLock {
            if let held = paths[path] { return .held(held) }
            paths[path] = .some(nil)
            return .claimed
        }
    }

    func register(_ ownership: SessionOwnership, at path: String) {
        lock.withLock { paths[path] = ownership }
    }

    func remove(_ path: String) {
        lock.withLock { _ = paths.removeValue(forKey: path) }
    }
}

/// Why a session's ownership could not be taken or let go, in acpx's words.
public struct SessionOwnershipError: LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Milliseconds since 1970, each later than the last.
private final class CreatedAt: @unchecked Sendable {
    private var last: Int64 = 0
    private let lock = NSLock()

    func next() -> Int64 {
        lock.withLock {
            last = max(Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)), last + 1)
            return last
        }
    }
}

extension POSIXError {
    /// The error `errno` holds, from `operation`.
    static func current(_ operation: String) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// `realpath(3)`, as a string: `nil` when it fails.
private func realpath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
