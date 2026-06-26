import Foundation
import JSONFoundation
import ACPXDaemonKit

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

/// Reads and writes acpx session records + index under `~/.acpx/sessions`,
/// faithfully to acpx 0.11.0 (`persistence/repository.ts`, `index.ts`).
public enum SessionStore {
    // MARK: Record IO

    public static func readRecord(at url: URL) -> SessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let record = try? recordDiskDecoder.decode(SessionRecord.self, from: data),
            record.schema == SESSION_RECORD_SCHEMA
        else { return nil }
        return record
    }

    public static func loadRecord(_ recordId: String) -> SessionRecord? {
        readRecord(at: ACPXPaths.sessionRecordPath(recordId))
    }

    /// Atomic write (temp + rename), pretty JSON + trailing newline, then index update.
    public static func writeRecord(_ record: SessionRecord) throws {
        try FileManager.default.createDirectory(
            at: ACPXPaths.sessionsDir, withIntermediateDirectories: true)
        let url = ACPXPaths.sessionRecordPath(record.acpxRecordId)
        try atomicWrite(encodeForDisk(record, using: recordDiskEncoder), to: url)
        try updateIndex(with: record)
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

    // MARK: Index

    public static func loadIndex() -> SessionIndex {
        let files = recordFilesOnDisk()
        if let data = try? Data(contentsOf: ACPXPaths.sessionIndexPath),
            let index = try? plainDecoder.decode(SessionIndex.self, from: data),
            index.files == files,
            index.entries.count == files.count {
            return index
        }
        return rebuildIndex(files: files)
    }

    private static func recordFilesOnDisk() -> [String] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: ACPXPaths.sessionsDir.path)) ?? []
        return contents.filter { $0.hasSuffix(".json") && $0 != "index.json" }.sorted()
    }

    private static func rebuildIndex(files: [String]) -> SessionIndex {
        var entries: [SessionIndexEntry] = []
        for file in files {
            let url = ACPXPaths.sessionsDir.appendingPathComponent(file)
            if let record = readRecord(at: url) {
                entries.append(SessionIndexEntry(record: record))
            }
        }
        entries.sort { $0.lastUsedAt > $1.lastUsedAt }
        let index = SessionIndex(files: files, entries: entries)
        try? writeIndex(index)
        return index
    }

    private static func updateIndex(with record: SessionRecord) throws {
        var index = loadIndex()
        let entry = SessionIndexEntry(record: record)
        index.entries.removeAll { $0.file == entry.file }
        index.entries.append(entry)
        index.entries.sort { $0.lastUsedAt > $1.lastUsedAt }
        if !index.files.contains(entry.file) {
            index.files.append(entry.file)
            index.files.sort()
        }
        try writeIndex(index)
    }

    private static func writeIndex(_ index: SessionIndex) throws {
        try atomicWrite(encodeForDisk(index, using: plainDiskEncoder), to: ACPXPaths.sessionIndexPath)
    }

    // MARK: Listing

    public static func listSessions() -> [SessionRecord] {
        loadIndex().entries.compactMap { entry in
            readRecord(at: ACPXPaths.sessionsDir.appendingPathComponent(entry.file))
        }.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public static func listSessions(forAgent agentCommand: String) -> [SessionRecord] {
        loadIndex().entries
            .filter { $0.agentCommand == agentCommand }
            .compactMap { readRecord(at: ACPXPaths.sessionsDir.appendingPathComponent($0.file)) }
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
        _ entry: SessionIndexEntry, cwd: String, name: String?, includeClosed: Bool
    ) -> Bool {
        guard entry.cwd == cwd else { return false }
        if !includeClosed && entry.closed { return false }
        let normalizedName = normalizeName(name)
        if normalizedName == nil { return normalizeName(entry.name) == nil }
        return normalizeName(entry.name) == normalizedName
    }

    /// Exact-cwd lookup (no ancestor walk). `findSession` in acpx.
    public static func findSession(
        agentCommand: String, cwd: String, name: String?, includeClosed: Bool = false
    ) -> SessionRecord? {
        let abs = absolute(cwd)
        for entry in loadIndex().entries
        where entry.agentCommand == agentCommand
            && matches(entry, cwd: abs, name: name, includeClosed: includeClosed) {
            if let record = readRecord(at: ACPXPaths.sessionsDir.appendingPathComponent(entry.file)) {
                return record
            }
        }
        return nil
    }

    /// Ancestor-walk lookup up to `boundary`. `findSessionByDirectoryWalk` in acpx.
    public static func findSessionByDirectoryWalk(
        agentCommand: String, cwd: String, name: String?, boundary: String?
    ) -> SessionRecord? {
        let entries = loadIndex().entries.filter { $0.agentCommand == agentCommand }
        let start = absolute(cwd)
        let resolvedBoundary = boundary.map(absolute)
        let walkBoundary =
            (resolvedBoundary != nil && isWithin(boundary: resolvedBoundary!, target: start))
            ? resolvedBoundary! : start

        var current = start
        while true {
            if let entry = entries.first(where: {
                matches($0, cwd: current, name: name, includeClosed: false)
            }) {
                if let record = readRecord(
                    at: ACPXPaths.sessionsDir.appendingPathComponent(entry.file)) {
                    return record
                }
            }
            guard let parent = nextWalkParent(current, boundary: walkBoundary) else { return nil }
            current = parent
        }
    }

    private static func isWithin(boundary: String, target: String) -> Bool {
        if boundary == target { return true }
        let rel = relativePath(from: boundary, to: target)
        return rel != "" && !rel.hasPrefix("..") && !rel.hasPrefix("/")
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

    /// Walk up looking for a directory containing a `.git` directory.
    public static func findGitRepositoryRoot(_ startDir: String) -> String? {
        var current = absolute(startDir)
        let fm = FileManager.default
        while true {
            var isDir: ObjCBool = false
            let gitPath = current + "/.git"
            if fm.fileExists(atPath: gitPath, isDirectory: &isDir), isDir.boolValue {
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
    public typealias HistoryEntry = ACPXDaemonKit.HistoryEntry

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
func encodeForDisk<T: Encodable>(_ value: T, using encoder: JSONEncoder) -> Data {
    ((try? encoder.encode(value)) ?? Data()) + Data("\n".utf8)
}

func atomicWrite(_ data: Data, to url: URL) throws {
    let temp = url.deletingLastPathComponent()
        .appendingPathComponent("\(url.lastPathComponent).\(getpid()).\(Int(Date().timeIntervalSince1970 * 1000)).tmp")
    try data.write(to: temp)
    _ = try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: temp, to: url)
}
