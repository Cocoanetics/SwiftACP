import Foundation
import JSONFoundation
import SwiftACP

public let DEFAULT_HISTORY_LIMIT = 20

/// ISO-8601 timestamp matching JS `new Date().toISOString()` — millis + `Z`.
public func nowISO() -> String {
    isoFormatter.string(from: Date())
}

/// ISO-8601 string for a specific date (same format as ``nowISO()``).
public func isoString(_ date: Date) -> String {
    isoFormatter.string(from: date)
}

// ISO8601DateFormatter is documented thread-safe for formatting.
private nonisolated(unsafe) let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

/// Reads and writes acpx session records under `~/.acpx/sessions`, faithfully to acpx
/// (`persistence/repository.ts`, `persistence/discovery.ts`).
///
/// Lookups resolve from the saved records themselves, never from cached metadata: a
/// record's filename must match its encoded id, a legacy `index.json` is ignored, and
/// concurrent writes are observed per record rather than as one atomic snapshot of the
/// store (acpx 0.19.0, `docs/sessions.md`).
public enum SessionStore {
    // MARK: Record IO

    /// Decode the record at `url`, optionally requiring it to be the record `recordId`
    /// names: a file claiming a different id is ignored, so a copy cannot answer for the
    /// record it was copied from (acpx's `readSessionRecord`).
    public static func readRecord(at url: URL, expecting recordId: String? = nil)
        -> SessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let record = try? recordDiskDecoder.decode(SessionRecord.self, from: data),
            record.schema == SESSION_RECORD_SCHEMA
        else { return nil }
        if let recordId, record.acpxRecordId != recordId { return nil }
        return record
    }

    /// Lookup by exact record id reads that one file — no scan (acpx, `docs/sessions.md`).
    public static func loadRecord(_ recordId: String) -> SessionRecord? {
        readRecord(at: ACPXPaths.sessionRecordPath(recordId), expecting: recordId)
    }

    /// Atomic write (temp + rename), pretty JSON + trailing newline. Nothing else is
    /// written: acpx dropped the shared index in 0.19.0, so a checkpoint can no longer
    /// fail on a second write after the record itself is committed.
    public static func writeRecord(_ record: SessionRecord) throws {
        try createSessionsDirectory()
        let url = ACPXPaths.sessionRecordPath(record.acpxRecordId)
        try atomicWrite(encodeForDisk(record, using: recordDiskEncoder), to: url)
    }

    /// `~/.acpx/sessions`, owner-only — the records and event logs inside hold whole
    /// conversations (acpx's `ensureSessionDir`, mode 0700).
    ///
    /// The mode is applied on creation *and* to a directory that already exists:
    /// `createDirectory` ignores `attributes` when the directory is already there, so a
    /// store created before this would otherwise keep its 0755 and stay traversable by
    /// other local users. Only the group and other bits are cleared, so an owner who
    /// tightened the directory further keeps their own mode.
    static func createSessionsDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: ACPXPaths.sessionsDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = ACPXPaths.sessionsDir.path
        guard let mode = (try? fm.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber
        else { return }
        let tightened = mode.uint16Value & ~UInt16(0o077)
        if tightened != mode.uint16Value {
            try? fm.setAttributes([.posixPermissions: tightened], ofItemAtPath: path)
        }
    }

    public static func deleteRecord(_ recordId: String, includeHistory: Bool) -> Int {
        var freed = 0
        let fm = FileManager.default
        let recordURL = ACPXPaths.sessionRecordPath(recordId)
        if let size = (try? fm.attributesOfItem(atPath: recordURL.path)[.size]) as? Int { freed += size }
        try? fm.removeItem(at: recordURL)
        if includeHistory {
            let active = ACPXPaths.sessionStreamPath(recordId)
            if let size = (try? fm.attributesOfItem(atPath: active.path)[.size]) as? Int { freed += size }
            try? fm.removeItem(at: active)
            for segment in 1 ... DEFAULT_EVENT_MAX_SEGMENTS {
                let url = ACPXPaths.sessionStreamSegmentPath(recordId, segment: segment)
                if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int { freed += size }
                try? fm.removeItem(at: url)
            }
        }
        return freed
    }

    // MARK: Discovery

    /// Every saved record, in filename order.
    ///
    /// A record whose filename does not match its own encoded id is skipped, so a copied
    /// record cannot answer for the one it names — nor authorize pruning it. A corrupt or
    /// concurrently removed file is skipped rather than hiding every other match. acpx's
    /// `scanSessionRecords`; a legacy `index.json` is ignored.
    public static func scanRecords() -> [SessionRecord] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: ACPXPaths.sessionsDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") && $0 != legacyIndexFileName }
            .sorted()
        return names.compactMap { name in
            guard let record = readRecord(at: ACPXPaths.sessionsDir.appendingPathComponent(name)),
                name == ACPXPaths.sessionRecordPath(record.acpxRecordId).lastPathComponent
            else { return nil }
            return record
        }
    }

    /// acpx kept a `sessions/index.json` until 0.19.0 and ignores it since; so do we.
    private static let legacyIndexFileName = "index.json"

    // MARK: Listing

    public static func listSessions() -> [SessionRecord] {
        scanRecords().sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public static func listSessions(forAgent agentCommand: String) -> [SessionRecord] {
        scanRecords()
            .filter { $0.agentCommand == agentCommand }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    // MARK: Routing

    public static func absolute(_ path: String) -> String {
        ACPXPaths.resolve(path, base: "/")
    }

    private static func normalizeName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func matches(
        _ record: SessionRecord, agentCommand: String, name: String?, includeClosed: Bool
    ) -> Bool {
        guard record.agentCommand == agentCommand else { return false }
        if !includeClosed && record.closed == true { return false }
        let normalizedName = normalizeName(name)
        if normalizedName == nil { return normalizeName(record.name) == nil }
        return normalizeName(record.name) == normalizedName
    }

    /// Whether `record` was used more recently than `previous` — acpx's `isNewer`.
    private static func isNewer(_ record: SessionRecord, than previous: SessionRecord?) -> Bool {
        guard let previous else { return true }
        return record.lastUsedAt > previous.lastUsedAt
    }

    /// Exact-cwd lookup (no ancestor walk). `findSession` in acpx: among the records saved
    /// for this cwd, the most recently used one wins.
    public static func findSession(
        agentCommand: String, cwd: String, name: String?, includeClosed: Bool = false
    ) -> SessionRecord? {
        let abs = absolute(cwd)
        var match: SessionRecord?
        for record in scanRecords() where record.cwd == abs {
            guard matches(
                record, agentCommand: agentCommand, name: name, includeClosed: includeClosed)
            else { continue }
            if isNewer(record, than: match) { match = record }
        }
        return match
    }

    /// Ancestor-walk lookup up to `boundary`. `findSessionByDirectoryWalk` in acpx: the
    /// directory nearest `cwd` wins, ties going to the most recently used record.
    public static func findSessionByDirectoryWalk(
        agentCommand: String, cwd: String, name: String?, boundary: String?
    ) -> SessionRecord? {
        let distances = walkDistances(cwd: cwd, boundary: boundary)
        var match: SessionRecord?
        var nearest = Int.max
        for record in scanRecords() {
            guard let distance = distances[record.cwd],
                matches(record, agentCommand: agentCommand, name: name, includeClosed: false)
            else { continue }
            if distance < nearest || (distance == nearest && isNewer(record, than: match)) {
                match = record
                nearest = distance
            }
        }
        return match
    }

    /// The directories the walk covers, each mapped to its distance from `cwd` (0 = `cwd`
    /// itself, rising towards the boundary). acpx's `walkDirectories`.
    private static func walkDistances(cwd: String, boundary: String?) -> [String: Int] {
        let start = absolute(cwd)
        let resolvedBoundary = boundary.map(absolute)
        let walkBoundary =
            (resolvedBoundary != nil && isWithin(boundary: resolvedBoundary!, target: start))
            ? resolvedBoundary! : start
        var distances: [String: Int] = [:]
        var current: String? = start
        while let directory = current {
            if distances[directory] == nil { distances[directory] = distances.count }
            current = nextWalkParent(directory, boundary: walkBoundary)
        }
        return distances
    }

    private static func isWithin(boundary: String, target: String) -> Bool {
        if boundary == target { return true }
        let rel = relativePath(from: boundary, to: target)
        // acpx's `isWithinBoundary`: only a relative path that *is* `..`, or steps up
        // through `../`, leaves the boundary. A bare `..` prefix test would also reject
        // a directory whose own name begins with two dots (`..foo`).
        return rel != "" && rel != ".." && !rel.hasPrefix("../") && !rel.hasPrefix("/")
    }

    private static func nextWalkParent(_ current: String, boundary: String) -> String? {
        if current == boundary { return nil }
        let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
        if parent == current { return nil }
        if !isWithin(boundary: boundary, target: parent) && parent != boundary { return nil }
        return parent
    }

    private static func relativePath(from base: String, to target: String) -> String {
        let baseParts = base.split(separator: "/").map(String.init)
        let targetParts = target.split(separator: "/").map(String.init)
        var i = 0
        while i < baseParts.count && i < targetParts.count && baseParts[i] == targetParts[i] { i += 1 }
        let ups = Array(repeating: "..", count: baseParts.count - i)
        let downs = targetParts[i...]
        let combined = ups + downs
        return combined.joined(separator: "/")
    }

    /// Walk up looking for a directory holding a `.git` entry — a directory in an
    /// ordinary clone, a *file* carrying a `gitdir:` pointer in a worktree or a
    /// submodule (acpx's `hasGitMarker`: `isDirectory() || isFile()`).
    public static func findGitRepositoryRoot(_ startDir: String) -> String? {
        var current = absolute(startDir)
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: current + "/.git") {
                return current
            }
            let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
            if parent == current { return nil }
            current = parent
        }
    }

    // MARK: History interpretation (conversationHistoryEntries)

    /// The `sessionHistory` row type now lives in the shared `ACPXDaemonKit` (so the
    /// generated daemon `Client` and iOS clients can decode it); aliased here so
    /// `SessionStore.HistoryEntry` call sites keep resolving.
    public typealias HistoryEntry = SwiftACP.HistoryEntry

    public static func conversationHistoryEntries(_ record: SessionRecord) -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        let timestamp = record.updatedAt
        for message in record.messages {
            switch message {
            case .resume:
                continue
            case .user(let user):
                let text = user.content.map(\.previewText).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    entries.append(.init(role: "user", timestamp: timestamp, textPreview: text))
                }
            case .agent(let agent):
                let text = agent.content.map(\.previewText).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    entries.append(.init(role: "assistant", timestamp: timestamp, textPreview: text))
                }
            }
        }
        return entries
    }
}

// MARK: - JSON + atomic write helpers

/// Encodes a value with the given encoder and appends acpx's trailing newline.
func encodeForDisk<T: Encodable>(_ value: T, using encoder: JSONEncoder) throws -> Data {
    try encoder.encode(value) + Data("\n".utf8)
}

/// Write `data` to `url` so a concurrent reader — another CLI invocation, `acpxd`, or
/// a real npm `acpx` sharing the same store — sees either the old file or the new one,
/// never a missing one, and so the result stays readable only by its owner.
///
/// `rename(2)` replaces the destination atomically. `FileManager.moveItem` cannot, which
/// is why this used to unlink the destination first and leave a window with no file at
/// all. Records hold whole conversations, so the file is created `0600` rather than at
/// the process umask (acpx keeps records and indexes private across atomic rewrites).
func atomicWrite(_ data: Data, to url: URL) throws {
    let temp = url.deletingLastPathComponent()
        .appendingPathComponent(temporaryWriteName(for: url.lastPathComponent))
    guard
        FileManager.default.createFile(
            atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
    else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
    }
    guard rename(temp.path, url.path) == 0 else {
        let failure = errno
        try? FileManager.default.removeItem(at: temp)
        throw NSError(
            domain: NSPOSIXErrorDomain, code: Int(failure),
            userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// A unique sibling name for `basename`'s temp file. Random rather than pid+millisecond
/// so two writes from one process cannot collide, and trimmed to keep the component
/// inside the 255-byte filesystem limit that a long session id would otherwise exceed.
private func temporaryWriteName(for basename: String) -> String {
    let suffix = ".\(UUID().uuidString.prefix(8)).tmp"
    var trimmed = basename
    while trimmed.utf8.count + suffix.utf8.count > 255 { trimmed.removeLast() }
    return trimmed + suffix
}
