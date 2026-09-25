@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// Reading a session's journal as acpx 0.19.1's `sessions watch` reads it (#59): its
/// events from a cursor on, across its segments, then as they are written.
@Suite(.serialized) struct SessionWatchTests {
    private func record(_ id: String, maxSegmentBytes: Int = 0, maxSegments: Int = 0) -> SessionRecord {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: id, acpSessionId: id, agentCommand: "codex", cwd: "/tmp", createdAt: now, lastUsedAt: now)
        if maxSegmentBytes > 0 { record.eventLog.maxSegmentBytes = maxSegmentBytes }
        if maxSegments > 0 { record.eventLog.maxSegments = maxSegments }
        return record
    }

    private let prompt = #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{}}"#
    private let answer = #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#

    /// One turn with `messages` in it, or only its start and messages when `finished` is false.
    private func turn(
        _ request: String, _ messages: [String], finished: Bool = true, writer: inout SessionEventLogWriter,
        record: inout SessionRecord
    ) throws {
        try writer.beginTurn(request, into: &record)
        try writer.append(messages.map { Data($0.utf8) }, into: &record)
        if finished { try writer.finishTurn(request, .settled(stopReason: "end_turn", meta: nil), into: &record) }
    }

    /// Each event as `<type> <request id>`.
    private func kinds(_ events: [SessionJournal.WatchEvent]) -> [String] {
        events.map { event in
            switch event.kind {
            case .message(let request, _): "message \(request ?? "-")"
            case .turnStarted(let request): "started \(request)"
            case .turnResult(let request, _): "result \(request)"
            }
        }
    }

    /// Watch `id`'s journal; `look` is asked whether to go on each time the watch has
    /// caught up, with the turn in flight.
    private func watch(
        _ id: String, cursor: String? = nil, maxSegments: Int = 5,
        look: (_ count: Int, _ pending: String?) throws -> Bool = { _, _ in false }
    ) async throws -> [SessionJournal.WatchEvent] {
        var events: [SessionJournal.WatchEvent] = []
        var looks = 0
        try await SessionJournal.watch(
            recordId: id, maxSegments: maxSegments, cursor: cursor,
            continueWatching: { pending in
                looks += 1
                return try look(looks, pending)
            },
            onEvent: { events.append($0) })
        return events
    }

    private func expectWatchError(_ code: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("no \(code)")
        } catch let error as SessionJournalError {
            #expect(error.code == code)
        } catch {
            Issue.record("\(error)")
        }
    }

    // MARK: Cursors

    /// As acpx writes them: base64url of `[recordId, sequence]` as JSON.
    @Test func aCursorIsAcpxs() throws {
        #expect(SessionJournal.cursor(recordId: "journal-session", sequence: 1) == "WyJqb3VybmFsLXNlc3Npb24iLDFd")
        #expect(SessionJournal.cursor(recordId: "journal-session", sequence: 10) == "WyJqb3VybmFsLXNlc3Npb24iLDEwXQ")
        let cursor = "WyJqb3VybmFsLXNlc3Npb24iLDEwXQ"
        #expect(try SessionJournal.sequence(ofCursor: cursor, recordId: "journal-session") == 10)
    }

    /// Only a cursor as acpx writes it is one: not padded, not in standard base64, not
    /// another JSON value, not a sequence that is negative, fractional or written otherwise.
    @Test(arguments: [
        "abc", "WyJqb3VybmFsLXNlc3Npb24iLDFd=", base64(#"["journal-session",1,2]"#), base64(#"{"a":1}"#),
        base64(#"["journal-session",-1]"#), base64(#"["journal-session",1.5]"#), base64(#"["journal-session",1.0]"#),
        base64(#"[ "journal-session",1]"#), base64(#"[1,1]"#)
    ])
    func onlyACursorAsWrittenIsOne(cursor: String) async {
        await expectWatchError("WATCH_CURSOR_INVALID") {
            _ = try SessionJournal.sequence(ofCursor: cursor, recordId: "journal-session")
        }
    }

    @Test func aCursorOfAnotherSessionIsForeign() async {
        await expectWatchError("WATCH_CURSOR_FOREIGN") {
            let cursor = SessionJournal.cursor(recordId: "other", sequence: 1)
            _ = try SessionJournal.sequence(ofCursor: cursor, recordId: "mine")
        }
    }

    private static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Watching

    /// Every event from the start of the journal, each turn's messages under its request
    /// id; then the watch asks whether to go on, no turn being in flight.
    @Test func aWatchReplaysTheJournalThenAsksWhetherToGoOn() async throws {
        try await withIsolatedStore {
            var seed = record("w-replay")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer], writer: &writer, record: &seed)
            try turn("req-2", [prompt, answer], writer: &writer, record: &seed)

            var asked: [String?] = []
            let events = try await watch("w-replay") { _, pending in
                asked.append(pending)
                return false
            }
            #expect(kinds(events) == [
                "started req-1", "message req-1", "message req-1", "result req-1",
                "started req-2", "message req-2", "message req-2", "result req-2"
            ])
            #expect(events.map(\.sequence) == Array(1...8))
            #expect(events.first?.cursor == SessionJournal.cursor(recordId: "w-replay", sequence: 1))
            #expect(asked == [nil])
        }
    }

    @Test func aWatchResumesAfterItsCursor() async throws {
        try await withIsolatedStore {
            var seed = record("w-resume")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer], writer: &writer, record: &seed)
            try turn("req-2", [prompt, answer], writer: &writer, record: &seed)

            let events = try await watch("w-resume", cursor: SessionJournal.cursor(recordId: "w-resume", sequence: 4))
            #expect(kinds(events) == ["started req-2", "message req-2", "message req-2", "result req-2"])
        }
    }

    /// A journal split into segments reads on from one to the next.
    @Test func aWatchReadsOnAcrossSegments() async throws {
        try await withIsolatedStore {
            var seed = record("w-segments", maxSegmentBytes: 300)
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer, prompt, answer], writer: &writer, record: &seed)
            let oldest = ACPXPaths.sessionStreamSegmentPath("w-segments", segment: 3)
            #expect(FileManager.default.fileExists(atPath: oldest.path))

            let events = try await watch("w-segments")
            #expect(kinds(events) == ["started req-1"] + Array(repeating: "message req-1", count: 4) + ["result req-1"])
            #expect(events.map(\.sequence) == Array(1...6))
        }
    }

    /// Once rotation has dropped the segment a cursor points into, it has expired.
    @Test func aCursorBeforeWhatIsRetainedHasExpired() async throws {
        try await withIsolatedStore {
            var seed = record("w-expired", maxSegmentBytes: 300, maxSegments: 2)
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer, prompt, answer], writer: &writer, record: &seed)

            await expectWatchError("WATCH_CURSOR_EXPIRED") {
                let cursor = SessionJournal.cursor(recordId: "w-expired", sequence: 1)
                _ = try await watch("w-expired", cursor: cursor, maxSegments: 2)
            }
        }
    }

    /// A cursor past the end of the journal, at the first read, is from the future.
    @Test func aCursorPastTheEndIsFromTheFuture() async throws {
        try await withIsolatedStore {
            var seed = record("w-future")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer], writer: &writer, record: &seed)

            await expectWatchError("WATCH_CURSOR_FUTURE") {
                _ = try await watch("w-future", cursor: SessionJournal.cursor(recordId: "w-future", sequence: 99))
            }
        }
    }

    /// What is written while the watch waits comes next; a turn started and not ended is
    /// the one in flight when the watch next asks.
    @Test func aWatchFollowsWhatIsWrittenMeanwhile() async throws {
        try await withIsolatedStore {
            var seed = record("w-follow")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer], writer: &writer, record: &seed)

            var asked: [String?] = []
            let events = try await watch("w-follow") { count, pending in
                asked.append(pending)
                if count == 1 { try turn("req-2", [prompt], finished: false, writer: &writer, record: &seed) }
                return count == 1
            }
            #expect(kinds(events).suffix(2) == ["started req-2", "message req-2"])
            #expect(asked == [nil, "req-2"])
        }
    }

    /// A watch called off ends quietly, where it is.
    @Test(.timeLimit(.minutes(1))) func aWatchCalledOffEndsQuietly() async throws {
        try await withIsolatedStore {
            var seed = record("w-cancel")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer], writer: &writer, record: &seed)

            let (caughtUp, catchingUp) = AsyncStream<Void>.makeStream()
            let watching = Task {
                try await SessionJournal.watch(
                    recordId: "w-cancel", maxSegments: 5, cursor: nil,
                    continueWatching: { _ in
                        catchingUp.yield()
                        return true
                    },
                    onEvent: { _ in })
            }
            for await _ in caughtUp { break }
            watching.cancel()
            try await watching.value
        }
    }

    /// A segment that got shorter under the watch was truncated.
    @Test func aSegmentTruncatedUnderAWatchIsCorrupt() async throws {
        try await withIsolatedStore {
            var seed = record("w-truncated")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer], writer: &writer, record: &seed)

            await expectWatchError("WATCH_JOURNAL_CORRUPT") {
                _ = try await watch("w-truncated") { count, _ in
                    let handle = try FileHandle(forWritingTo: ACPXPaths.sessionStreamPath("w-truncated"))
                    try handle.truncate(atOffset: 10)
                    try handle.close()
                    return count == 1
                }
            }
        }
    }

    /// Segments whose anchors do not follow on from each other are not one journal.
    @Test func segmentsThatDoNotFollowOnAreCorrupt() async throws {
        try await withIsolatedStore {
            let anchor = { (sequence: Int) in
                #"{"schema":"acpx.session.journal.v1","type":"segment","record_id":"w-gap","sequence":\#(sequence),"#
                    + #""message_sequence":0,"request_id":null}"# + "\n"
            }
            try FileManager.default.createDirectory(
                at: ACPXPaths.sessionStreamPath("w-gap").deletingLastPathComponent(), withIntermediateDirectories: true)
            try (anchor(0) + prompt + "\n").write(
                to: ACPXPaths.sessionStreamSegmentPath("w-gap", segment: 1), atomically: true, encoding: .utf8)
            try (anchor(5) + answer + "\n").write(
                to: ACPXPaths.sessionStreamPath("w-gap"), atomically: true, encoding: .utf8)

            await expectWatchError("WATCH_JOURNAL_CORRUPT") { _ = try await watch("w-gap") }
        }
    }

    /// A read stops once its page is full; the next goes on from there.
    @Test func aReadStopsOnceItsPageIsFull() async throws {
        try await withIsolatedStore {
            var seed = record("w-page")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer, prompt, answer], writer: &writer, record: &seed)

            let reader = SessionJournal.Reader(recordId: "w-page", maxSegments: 5)
            let first = try await reader.read(after: -1, maxBytes: 150)
            #expect(first.hasMore)
            let read = first.events.map(\.sequence)
            #expect(!read.isEmpty && read.count < 6, "\(read)")
            let second = try await reader.read(after: try #require(read.last), maxBytes: 1_000_000)
            #expect(!second.hasMore)
            #expect(read + second.events.map(\.sequence) == Array(1...6))
        }
    }
}
