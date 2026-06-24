import Foundation
import JSONFoundation

/// A thread-safe FIFO buffer the JSON-RPC wire observer pushes lines into
/// (synchronously, from the connection), and the ``TurnPersister`` drains on each
/// checkpoint — mirroring acpx's `pendingMessages` array.
public final class WireBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    public init() {}

    public func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    public func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let drained = lines
        lines.removeAll(keepingCapacity: true)
        return drained
    }
}

/// Appends raw JSON-RPC wire lines to a session's `<id>.stream.ndjson` event log,
/// rotating segments at the configured size and keeping the record's `event_log`
/// metadata (and `last_seq` / `last_request_id` / `last_used_at`) current.
///
/// A faithful port of acpx 0.11.0's `SessionEventWriter`, minus the cross-process
/// `.stream.lock`: the single daemon process owns the session, and the lock
/// leaves no trace in the persisted record.
public struct SessionEventLogWriter {
    private let recordId: String
    private let maxSegmentBytes: Int
    private let maxSegments: Int
    private var activeSizeBytes: Int
    private var segmentCount: Int

    public init(record: SessionRecord) {
        recordId = record.acpxRecordId
        maxSegmentBytes =
            record.eventLog.maxSegmentBytes > 0
            ? record.eventLog.maxSegmentBytes : DEFAULT_EVENT_SEGMENT_MAX_BYTES
        maxSegments =
            record.eventLog.maxSegments > 0 ? record.eventLog.maxSegments : DEFAULT_EVENT_MAX_SEGMENTS
        activeSizeBytes = Self.fileSize(ACPXPaths.sessionStreamPath(record.acpxRecordId))
        segmentCount = record.eventLog.segmentCount > 0 ? record.eventLog.segmentCount : 1
    }

    /// Append each wire `line` to the active segment (rotating first if it would
    /// overflow `maxSegmentBytes`) and update the record's event-log metadata.
    public mutating func append(_ lines: [String], into record: inout SessionRecord) {
        guard !lines.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: ACPXPaths.sessionsDir, withIntermediateDirectories: true)

        for line in lines {
            let entry = line + "\n"
            let bytes = entry.utf8.count
            if activeSizeBytes > 0, activeSizeBytes + bytes > maxSegmentBytes {
                rotate()
                activeSizeBytes = 0
                segmentCount = min(segmentCount + 1, maxSegments)
            }
            appendToActive(entry)
            activeSizeBytes += bytes

            record.lastSeq += 1
            if let id = Self.messageId(line) { record.lastRequestId = id }
            let writeTs = nowISO()
            record.lastUsedAt = writeTs
            record.eventLog.activePath = ACPXPaths.sessionStreamPath(recordId).path
            record.eventLog.segmentCount = segmentCount
            record.eventLog.maxSegmentBytes = maxSegmentBytes
            record.eventLog.maxSegments = maxSegments
            record.eventLog.lastWriteAt = writeTs
            record.eventLog.lastWriteError = nil
        }
    }

    private func appendToActive(_ text: String) {
        let url = ACPXPaths.sessionStreamPath(recordId)
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Rotate segments: drop the overflow segment, shift `.n` → `.n+1`, then move
    /// the active log to `.1` (matches acpx's `rotateSegments`).
    private func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(at: ACPXPaths.sessionStreamSegmentPath(recordId, segment: maxSegments))
        var segment = maxSegments - 1
        while segment >= 1 {
            let from = ACPXPaths.sessionStreamSegmentPath(recordId, segment: segment)
            if fm.fileExists(atPath: from.path) {
                let to = ACPXPaths.sessionStreamSegmentPath(recordId, segment: segment + 1)
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
            segment -= 1
        }
        let active = ACPXPaths.sessionStreamPath(recordId)
        if fm.fileExists(atPath: active.path) {
            let dest = ACPXPaths.sessionStreamSegmentPath(recordId, segment: 1)
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: active, to: dest)
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    /// A JSON-RPC `id` (string or number) from a wire line, for `last_request_id`.
    private static func messageId(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let object) = json, let id = object["id"]
        else { return nil }
        switch id {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        default: return nil
        }
    }
}
