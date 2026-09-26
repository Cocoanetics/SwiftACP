import Foundation
import SwiftACP

// Reading a session's journal as acpx's `sessions watch` reads it (`session/journal.ts`,
// 0.19.1): its events from a cursor on, then as they come, without touching the session.
extension SessionJournal {
    /// One event of a session's journal: acpx's `SessionWatchEvent`. A message of the ACP
    /// exchange, or a turn's start or result.
    public struct WatchEvent: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A message of the exchange, and the turn it came in, if one had started.
            case message(requestId: String?, WireJSON)
            case turnStarted(requestId: String)
            /// A turn's result, as its `turn_result` record carries it.
            case turnResult(requestId: String, WireJSON)
        }

        /// Where the journal stands once this event is read: a watch resumed with it starts
        /// after the event.
        public let cursor: String
        public let kind: Kind
        /// The event's place in the journal.
        let sequence: Int

        init(recordId: String, sequence: Int, kind: Kind) {
            self.cursor = SessionJournal.cursor(recordId: recordId, sequence: sequence)
            self.kind = kind
            self.sequence = sequence
        }

        /// The event as acpx's JSON output prints it: `cursor`, `type`, `requestId`, then the
        /// message or the result. `message` stands in for the message, as the output shows it.
        public func json(message shown: WireJSON? = nil) -> WireJSON {
            var members: [WireJSON.Member] = [.init("cursor", .text(cursor))]
            switch kind {
            case let .message(requestId, message):
                members += [
                    .init("type", .text("message")), .init("requestId", requestId.map(WireJSON.text) ?? .null),
                    .init("message", shown ?? message)
                ]
            case .turnStarted(let requestId):
                members += [.init("type", .text("turn_started")), .init("requestId", .text(requestId))]
            case let .turnResult(requestId, result):
                members += [
                    .init("type", .text("turn_result")), .init("requestId", .text(requestId)), .init("result", result)
                ]
            }
            return .object(members)
        }
    }

    /// A page of events being read: acpx's `JournalPage`, which its `eventSink` fills. Only
    /// events past `after` go on it, and only their lines count toward `maxBytes`.
    struct Page {
        let after: Int
        let maxBytes: Int
        var bytes = 0
        var events: [WatchEvent] = []

        var isFull: Bool { bytes >= maxBytes }

        mutating func add(_ sequence: Int, of recordId: String, bytes: Int, _ kind: () -> WatchEvent.Kind) {
            guard sequence > after else { return }
            self.bytes += bytes
            events.append(WatchEvent(recordId: recordId, sequence: sequence, kind: kind()))
        }
    }

    // MARK: Cursors

    /// acpx's `sessionWatchCursor`: `[recordId, sequence]` as JSON, in base64url.
    public static func cursor(recordId: String, sequence: Int) -> String {
        let json = WireJSON.array([.text(recordId), .number(Double(sequence))]).stringified
        return Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// acpx's `parseCursor`: the sequence a cursor of `recordId`'s journal names. Only a
    /// cursor as ``cursor(recordId:sequence:)`` writes it is one.
    public static func sequence(ofCursor cursor: String, recordId: String) throws -> Int {
        let invalid = SessionJournalError(code: "WATCH_CURSOR_INVALID", message: "Invalid session watch cursor")
        var base64 = cursor.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              case .array(let tuple)? = try? WireJSON.parse(String(decoding: data, as: UTF8.self)),
              tuple.count == 2, let owner = tuple[0].stringValue, case .number(let number) = tuple[1],
              number >= 0, number <= 9_007_199_254_740_991, number == number.rounded(),
              Self.cursor(recordId: owner, sequence: Int(number)) == cursor
        else { throw invalid }
        guard owner == recordId else {
            throw SessionJournalError(code: "WATCH_CURSOR_FOREIGN", message: "Cursor belongs to another session")
        }
        return Int(number)
    }

    // MARK: Watching

    /// How much of the journal one read takes on: acpx's `WATCH_PAGE_BYTES`.
    static let watchPageBytes = 1024 * 1024

    /// acpx's `watchSession`: the events of `recordId`'s journal after `cursor`, from the
    /// start of what it retains without one, and then those still to come, each handed to
    /// `onEvent` in turn. Once a read has caught up, `continueWatching` says whether to go
    /// on, given the turn the journal has started and not ended; the next read comes
    /// 100 ms later. Ends quietly when cancelled.
    ///
    /// Told not to go on — or that the turn's outcome is unknown (`WATCH_OUTCOME_UNKNOWN`)
    /// — it reads again at once, as acpx 0.19.3 drains what the journal still holds before
    /// it takes a terminal outcome (#719): only a read that finds nothing new under the
    /// same turn ends the watch, or throws the unknown outcome. One that finds more hands
    /// it on, and asks again.
    public static func watch(
        recordId: String, maxSegments: Int, cursor: String?,
        continueWatching: (_ pendingRequestId: String?) async throws -> Bool,
        onEvent: (WatchEvent) async throws -> Void
    ) async throws {
        var after = try cursor.map { try sequence(ofCursor: $0, recordId: recordId) } ?? -1
        let reader = Reader(recordId: recordId, maxSegments: maxSegments)
        var first = true
        // A decision to stop, not yet confirmed by a read that finds nothing new.
        var stopping: (requestId: String?, unknown: SessionJournalError?)?
        do {
            while !Task.isCancelled {
                let snapshot = try await reader.read(after: after, maxBytes: watchPageBytes)
                try assertRetained(after, snapshot, first: first)
                first = false
                for event in snapshot.events {
                    guard !Task.isCancelled else { return }
                    after = event.sequence
                    try await onEvent(event)
                }
                if let decided = stopping {
                    stopping = nil
                    if snapshot.events.isEmpty, !snapshot.hasMore, snapshot.requestId == decided.requestId {
                        if let unknown = decided.unknown { throw unknown }
                        return
                    }
                }
                if !snapshot.hasMore {
                    do {
                        if try await !continueWatching(snapshot.requestId) {
                            stopping = (snapshot.requestId, nil)
                            continue
                        }
                    } catch let unknown as SessionJournalError where unknown.code == "WATCH_OUTCOME_UNKNOWN" {
                        stopping = (snapshot.requestId, unknown)
                        continue
                    }
                }
                try await Task.sleep(nanoseconds: snapshot.hasMore ? 0 : 100_000_000)
            }
        } catch is CancellationError {
            return
        }
    }

    /// acpx's `assertRetainedCursor`: a cursor past the journal's end, or before what it
    /// still retains, is not one to resume from.
    private static func assertRetained(_ after: Int, _ snapshot: Snapshot, first: Bool) throws {
        guard after >= 0 else { return }
        if after > snapshot.sequence {
            throw SessionJournalError(
                code: first ? "WATCH_CURSOR_FUTURE" : "WATCH_CURSOR_EXPIRED",
                message: "Cursor is beyond the available session journal")
        }
        if let firstSequence = snapshot.firstSequence, after < firstSequence {
            throw SessionJournalError(
                code: "WATCH_CURSOR_EXPIRED", message: "Cursor is older than retained session history")
        }
    }

    // MARK: Reading

    /// What one read found: acpx's `read` result.
    struct Snapshot {
        var events: [WatchEvent]
        /// The page filled before the journal's end.
        var hasMore: Bool
        /// Where the oldest retained segment starts.
        var firstSequence: Int?
        /// Where the journal ends, and the turn it has started and not ended.
        var sequence: Int
        var requestId: String?
    }

    /// acpx's `SessionJournalReader`: the journal's segments, oldest first, each read on
    /// from where the last read left it. Its state is kept per file, so a segment that
    /// rotation renames is read on from where it was too. A page moves it on only once it
    /// is read through, from a capture that held still, and not called off (#753): one
    /// that fails leaves it where the last page did, so nothing is skipped.
    final class Reader {
        private let recordId: String
        private let paths: [String]
        private var states: [FileIdentity: SegmentState] = [:]

        init(recordId: String, maxSegments: Int) {
            self.recordId = recordId
            let segments = max(maxSegments, 1)
            paths = stride(from: segments, through: 1, by: -1).map {
                ACPXPaths.sessionStreamSegmentPath(recordId, segment: $0).path
            } + [ACPXPaths.sessionStreamPath(recordId).path]
        }

        func read(after: Int, maxBytes: Int) async throws -> Snapshot {
            while true {
                if let (snapshot, read) = try SessionJournal.capture(paths, { try page(after, maxBytes, $0) }) {
                    try Task.checkCancellation()
                    states = read
                    return snapshot
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        /// A page of `segments`, and where it leaves each: the reader's state is kept apart
        /// until the page is had.
        private func page(
            _ after: Int, _ maxBytes: Int, _ segments: [OpenSegment]
        ) throws -> (Snapshot, [FileIdentity: SegmentState]) {
            var page: Page? = Page(after: after, maxBytes: maxBytes)
            var states = self.states
            var hasMore = false
            var firstSequence: Int?
            var tail = SegmentState()
            for segment in segments {
                try Task.checkCancellation()
                var state = states[segment.identity] ?? SegmentState()
                try read(segment, into: &state, page: &page)
                states[segment.identity] = state
                if let first = state.firstSequence {
                    if firstSequence == nil {
                        firstSequence = first
                    } else if first != tail.sequence {
                        throw SessionJournalError.corrupt("Session journal segments are not contiguous")
                    }
                    tail = state
                }
                if page?.isFull == true {
                    hasMore = true
                    break
                }
            }
            let retained = Set(segments.map(\.identity))
            let snapshot = Snapshot(
                events: page?.events ?? [], hasMore: hasMore, firstSequence: firstSequence, sequence: tail.sequence,
                requestId: tail.requestId)
            return (snapshot, states.filter { retained.contains($0.key) })
        }

        /// acpx's `readSegment`: what the segment holds past where it was left, until the page
        /// is full. A segment shorter than what was read of it was truncated under the watch.
        private func read(_ segment: OpenSegment, into state: inout SegmentState, page: inout Page?) throws {
            guard segment.size >= state.offset else {
                throw SessionJournalError.corrupt("Session journal was truncated while watching")
            }
            var buffer = [UInt8](repeating: 0, count: min(64 * 1024, segment.size - state.offset))
            while true {
                try state.consumePending(recordId: recordId, page: &page)
                if page?.isFull == true || state.offset >= segment.size { return }
                let count = pread(segment.descriptor, &buffer, min(buffer.count, segment.size - state.offset),
                                  off_t(state.offset))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SessionJournal.failure("read", segment.path)
                }
                guard count > 0 else { throw SessionJournalError.corrupt("Session journal changed while reading") }
                state.offset += count
                state.pending.append(contentsOf: buffer[0..<count])
            }
        }
    }

    /// `syscall` on `path` failing with `errno`, as Node words it.
    static func failure(_ syscall: String, _ path: String) -> SessionArchive.Failure {
        let code = errno
        return SessionArchive.Failure(message: NodePath.errorMessage(code, syscall: syscall, path: path), code: code)
    }

    /// A file as acpx's `fileIdentity` tells it apart: its device, inode, and when it was
    /// made, where the platform says.
    struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
        let birth: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            #if canImport(Darwin)
            birth = Int64(status.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_birthtimespec.tv_nsec)
            #else
            birth = 0
            #endif
        }

        /// The file at `path` now, or `nil` when there is none.
        init?(ofPath path: String) throws {
            var status = stat()
            guard lstat(path, &status) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { return nil }
                throw SessionJournal.failure("lstat", path)
            }
            self.init(status)
        }
    }
}
