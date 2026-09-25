import Foundation
import JSONFoundation
import SwiftACP

/// A thread-safe FIFO buffer an agent's raw wire tap pushes each message into
/// (synchronously, from the transport), and the ``TurnPersister`` drains on each
/// checkpoint — acpx's `pendingMessages` array. It keeps the bytes as they crossed the
/// wire: the log prints each message from them, as acpx prints the message it parsed.
///
/// `@unchecked Sendable`: `lock` guards every access to `bodies`, the only mutable state.
public final class WireBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []

    public init() {}

    public func append(_ body: Data) {
        lock.withLock { bodies.append(body) }
    }

    public func drain() -> [Data] {
        lock.withLock {
            defer { bodies.removeAll(keepingCapacity: true) }
            return bodies
        }
    }
}

/// acpx's `SessionEventWriter`: appends to a session's event log (`<id>.stream.ndjson`)
/// its ACP messages, each as `JSON.stringify` prints the message it parsed, and the
/// journal's records (``SessionJournal``): `turn_started` and `turn_result` around each
/// turn, and a `segment` anchor at the head of each segment. Segments rotate at the
/// configured size, and each write keeps the record's `event_log` and `last_used_at`
/// current; each message, its `last_seq` and `last_request_id`.
///
/// Opened, it reads where the journal left off: the record's `last_seq` is taken from
/// there, and a log without an anchor — one an older writer or an import left — or one
/// ending in part of a line is rotated away before the first write. A turn the journal
/// started and never ended, its writer gone down with it, is ended as of unknown outcome
/// when the next one begins.
///
/// Without acpx's cross-process `.stream.lock`: the daemon alone writes a session's log.
public struct SessionEventLogWriter {
    private let recordId: String
    private let maxSegmentBytes: Int
    private let maxSegments: Int
    private var activeSizeBytes: Int
    private var segmentCount: Int
    /// Journal records so far: messages and turn records, not anchors.
    private var sequence: Int
    /// The turn the journal has started and not ended.
    private var requestId: String?
    /// Whether that turn is one an earlier writer left open.
    private var recoveryPending: Bool
    private var needsAnchor: Bool
    private var needsRotation: Bool
    /// Records in the active segment after its anchor.
    private var activeEntries: Int
    /// A write that failed: the log may end in part of a line, so nothing more is
    /// written, and what comes next — the turn's result above all — fails with it.
    private var appendFailure: Error?

    /// acpx's `SessionEventWriter.open`: a writer that goes on from where `record`'s
    /// journal left off, `record`'s `last_seq` brought in line with it. A journal that
    /// cannot be read so throws — ``SessionJournalError`` for one that is corrupt.
    public static func open(record: inout SessionRecord) throws -> SessionEventLogWriter {
        let maxSegmentBytes =
            record.eventLog.maxSegmentBytes > 0 ? record.eventLog.maxSegmentBytes : DEFAULT_EVENT_SEGMENT_MAX_BYTES
        let maxSegments = record.eventLog.maxSegments > 0 ? record.eventLog.maxSegments : DEFAULT_EVENT_MAX_SEGMENTS
        let tail = try SessionJournal.readTail(recordId: record.acpxRecordId, maxSegments: maxSegments)
        if let messageSequence = tail.messageSequence { record.lastSeq = messageSequence }
        return SessionEventLogWriter(
            record: record, maxSegmentBytes: maxSegmentBytes, maxSegments: maxSegments, tail: tail)
    }

    private init(record: SessionRecord, maxSegmentBytes: Int, maxSegments: Int, tail: SessionJournal.Tail) {
        recordId = record.acpxRecordId
        self.maxSegmentBytes = maxSegmentBytes
        self.maxSegments = maxSegments
        activeSizeBytes = tail.activeSize
        segmentCount = record.eventLog.segmentCount > 0
            ? record.eventLog.segmentCount : max(Self.existingSegments(record.acpxRecordId, maxSegments), 1)
        sequence = tail.sequence
        requestId = tail.requestId
        recoveryPending = tail.requestId != nil
        needsAnchor = !tail.activeAnchored
        needsRotation = tail.activeSize > 0 && (!tail.activeAnchored || tail.activePartial)
        activeEntries = tail.activeAnchored ? 1 : 0
    }

    /// acpx's `beginTurn`: `turn_started` for `requestId` — after a failed result for a
    /// turn an earlier writer left open.
    public mutating func beginTurn(_ requestId: String, into record: inout SessionRecord) throws {
        if let open = self.requestId {
            guard recoveryPending else { throw JournalStateError(message: "A session journal turn is already active") }
            try write(SessionJournal.turnResult(open, .outcomeUnknown), into: &record)
            self.requestId = nil
        }
        recoveryPending = false
        try write(SessionJournal.turnStarted(requestId), into: &record)
        self.requestId = requestId
    }

    /// acpx's `finishTurn`: `turn_result` for the turn begun.
    public mutating func finishTurn(
        _ requestId: String, _ result: SessionJournal.TurnResult, into record: inout SessionRecord
    ) throws {
        guard requestId == self.requestId else {
            throw JournalStateError(message: "Session journal result does not match the active request")
        }
        try write(SessionJournal.turnResult(requestId, result), into: &record)
        self.requestId = nil
    }

    /// acpx's `appendMessages`: each message, from its bytes on the wire, as
    /// `JSON.stringify` prints it. What is not an ACP message is left out — acpx refuses
    /// to write one.
    public mutating func append(_ bodies: [Data], into record: inout SessionRecord) throws {
        for body in bodies {
            guard let message = WireJSON(parsing: body), SessionArchive.isACPMessage(message) else { continue }
            try write(message, into: &record)
            record.lastSeq += 1
            switch message["id"] {
            case .string(let units)?: record.lastRequestId = String(decoding: units, as: UTF16.self)
            case .number(let number)?: record.lastRequestId = WireJSON.javaScriptString(for: number)
            default: break
            }
        }
    }

    /// acpx's `appendEntry`: one record, unless an earlier one failed.
    private mutating func write(_ entry: WireJSON, into record: inout SessionRecord) throws {
        if let appendFailure { throw appendFailure }
        do {
            try writeEntry(entry, into: &record)
        } catch {
            appendFailure = error
            throw error
        }
    }

    /// acpx's `writeEntry`: rotating first when the line would overflow the segment, and
    /// anchoring a segment before its first record.
    private mutating func writeEntry(_ entry: WireJSON, into record: inout SessionRecord) throws {
        try SessionStore.createSessionsDirectory()
        let line = entry.stringified + "\n"
        let lineBytes = line.utf8.count
        if needsRotation || (activeEntries > 0 && activeSizeBytes + lineBytes > maxSegmentBytes) {
            try rotate()
            activeSizeBytes = 0
            activeEntries = 0
            needsAnchor = true
            needsRotation = false
            segmentCount = min(segmentCount + 1, maxSegments)
        }
        if needsAnchor {
            let anchor = SessionJournal.anchor(
                recordId: recordId, sequence: sequence, messageSequence: record.lastSeq, requestId: requestId)
            let header = anchor.stringified + "\n"
            try appendToActive(header)
            activeSizeBytes += header.utf8.count
            needsAnchor = false
        }
        try appendToActive(line)
        activeSizeBytes += lineBytes
        activeEntries += 1
        sequence += 1
        let writeTs = nowISO()
        record.lastUsedAt = writeTs
        record.eventLog.activePath = ACPXPaths.sessionStreamPath(recordId).path
        record.eventLog.segmentCount = segmentCount
        record.eventLog.maxSegmentBytes = maxSegmentBytes
        record.eventLog.maxSegments = maxSegments
        record.eventLog.lastWriteAt = writeTs
        record.eventLog.lastWriteError = nil
    }

    /// fs-safe's `appendRegularFile`: `text` onto the active segment, created owner-only
    /// — the log is the whole conversation, verbatim — and never through a symbolic link.
    private func appendToActive(_ text: String) throws {
        let path = ACPXPaths.sessionStreamPath(recordId).path
        let descriptor = Foundation.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.failure(errno, "open", path) }
        defer { close(descriptor) }
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                throw Self.failure(errno, "write", nil)
            }
            bytes = bytes.dropFirst(written)
        }
    }

    /// acpx's `rotateSegments`: the oldest segment dropped, each other moved one on, and
    /// the active log made segment 1.
    private func rotate() throws {
        let overflow = ACPXPaths.sessionStreamSegmentPath(recordId, segment: maxSegments).path
        if unlink(overflow) != 0, errno != ENOENT { throw Self.failure(errno, "unlink", overflow) }
        for segment in stride(from: maxSegments - 1, through: 1, by: -1) {
            let from = ACPXPaths.sessionStreamSegmentPath(recordId, segment: segment).path
            let to = ACPXPaths.sessionStreamSegmentPath(recordId, segment: segment + 1).path
            try Self.move(from, to)
        }
        try Self.move(
            ACPXPaths.sessionStreamPath(recordId).path, ACPXPaths.sessionStreamSegmentPath(recordId, segment: 1).path)
    }

    /// `from` renamed to `to` when it is there.
    private static func move(_ from: String, _ to: String) throws {
        guard access(from, F_OK) == 0 else { return }
        if rename(from, to) != 0 { throw failure(errno, "rename", from) }
    }

    /// acpx's `countExistingSegments`: the segments there, the active one with them.
    private static func existingSegments(_ recordId: String, _ maxSegments: Int) -> Int {
        let segments = (1...max(maxSegments, 1)).map { ACPXPaths.sessionStreamSegmentPath(recordId, segment: $0).path }
        return (segments + [ACPXPaths.sessionStreamPath(recordId).path]).filter { access($0, F_OK) == 0 }.count
    }

    private static func failure(_ code: Int32, _ syscall: String, _ path: String?) -> SessionArchive.Failure {
        SessionArchive.Failure(message: NodePath.errorMessage(code, syscall: syscall, path: path), code: code)
    }
}

/// The writer asked to do what the journal's state does not allow.
struct JournalStateError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
