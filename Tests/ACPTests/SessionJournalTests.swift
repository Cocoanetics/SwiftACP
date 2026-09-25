@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// A session's event log is acpx 0.19.1's journal (#89): each turn between its
/// `turn_started` and `turn_result`, keyed by the turn's request id; a `segment` anchor at
/// the head of each segment, saying where in the journal it starts; and each message as
/// `JSON.stringify` prints the message it parsed.
@Suite(.serialized) struct SessionJournalTests {
    private static let schema = #"{"schema":"acpx.session.journal.v1","type":"#

    private func record(_ id: String, maxSegmentBytes: Int = 0) -> SessionRecord {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: id, acpSessionId: id, agentCommand: "codex", cwd: "/tmp", createdAt: now, lastUsedAt: now)
        if maxSegmentBytes > 0 { record.eventLog.maxSegmentBytes = maxSegmentBytes }
        return record
    }

    private func body(_ text: String) -> Data { Data(text.utf8) }

    /// The lines of the active segment, or of segment `segment`.
    private func lines(_ id: String, segment: Int? = nil) throws -> [String] {
        let url = segment.map { ACPXPaths.sessionStreamSegmentPath(id, segment: $0) } ?? ACPXPaths.sessionStreamPath(id)
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func anchor(_ id: String, _ sequence: Int, _ messages: Int, _ request: String?) -> String {
        Self.schema + #""segment","record_id":"\#(id)","sequence":\#(sequence),"message_sequence":\#(messages),"#
            + #""request_id":\#(request.map { "\"\($0)\"" } ?? "null")}"#
    }

    private func started(_ request: String) -> String {
        Self.schema + #""turn_started","request_id":"\#(request)"}"#
    }

    private func completed(_ request: String) -> String {
        Self.schema + #""turn_result","request_id":"\#(request)","#
            + #""result":{"status":"completed","stopReason":"end_turn"}}"#
    }

    /// One turn with `messages` in it.
    private func turn(
        _ request: String, _ messages: [String], writer: inout SessionEventLogWriter, record: inout SessionRecord
    ) throws {
        try writer.beginTurn(request, into: &record)
        try writer.append(messages.map(body), into: &record)
        try writer.finishTurn(request, .settled(stopReason: "end_turn", meta: nil), into: &record)
    }

    private let prompt = #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{}}"#
    private let answer = #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#

    @Test func aTurnIsLoggedBetweenItsJournalRecords() async throws {
        try await withIsolatedStore {
            var seed = record("j-turn")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer], writer: &writer, record: &seed)

            #expect(try lines("j-turn") == [
                anchor("j-turn", 0, 0, nil), started("req-1"), prompt, answer, completed("req-1")
            ])
            // `last_seq` counts the messages, not the journal's records.
            #expect(seed.lastSeq == 2)
            #expect(seed.eventLog.lastWriteAt != nil)
        }
    }

    /// Key order kept, and JavaScript's forms: `1.50` is `1.5`, and an escaped letter is
    /// the letter. What is not an ACP message is left out.
    @Test func messagesAreLoggedAsJSONStringifyPrintsThem() async throws {
        try await withIsolatedStore {
            var seed = record("j-form")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try writer.beginTurn("req-1", into: &seed)
            try writer.append([
                body(#"{"params":{"n":1.50,"text":"café \/"},"method":"session/update","jsonrpc":"2.0"}"#),
                body(#"{"not":"a message"}"#), body("not json")
            ], into: &seed)

            #expect(try lines("j-form").last
                == #"{"params":{"n":1.5,"text":"café /"},"method":"session/update","jsonrpc":"2.0"}"#)
            #expect(seed.lastSeq == 1)
        }
    }

    @Test func aTurnsResultSaysHowItEnded() {
        let meta = WireJSON.object([.init("z", .number(1)), .init("a", .text("é"))])
        #expect(SessionJournal.turnResult("r", .settled(stopReason: "cancelled", meta: meta)).stringified
            == Self.schema + #""turn_result","request_id":"r","result":{"status":"cancelled","stopReason":"cancelled","#
            + #""_meta":{"z":1,"a":"é"}}}"#)
        // acpx's `failedWatchResult`: the error normalized, the detail code defaulted.
        let timedOut = TurnFailure.journalResult(for: TimeoutError(milliseconds: 500))
        #expect(timedOut == .failed(
            message: "Timed out after 500ms", code: "TIMEOUT", detailCode: "QUEUE_RUNTIME_PROMPT_FAILED",
            retryable: nil))
        #expect(SessionJournal.turnResult("r", timedOut).stringified
            == Self.schema + #""turn_result","request_id":"r","result":{"status":"failed","error":{"#
            + #""message":"Timed out after 500ms","code":"TIMEOUT","detailCode":"QUEUE_RUNTIME_PROMPT_FAILED"}}}"#)
    }

    /// Each segment starts with an anchor: the journal's records and messages before it,
    /// and the turn under way.
    @Test func eachSegmentIsAnchoredWhereItStarts() async throws {
        try await withIsolatedStore {
            var seed = record("j-seg", maxSegmentBytes: 300)
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer, prompt, answer], writer: &writer, record: &seed)

            // As acpx 0.19.1's own writer splits it: a record that would take a segment past
            // 300 bytes starts the next one, whose anchor counts the records and messages
            // before it, mid-turn.
            #expect(try lines("j-seg", segment: 3) == [anchor("j-seg", 0, 0, nil), started("req-1"), prompt])
            #expect(try lines("j-seg", segment: 2) == [anchor("j-seg", 2, 1, "req-1"), answer, prompt])
            #expect(try lines("j-seg", segment: 1) == [anchor("j-seg", 4, 3, "req-1"), answer])
            #expect(try lines("j-seg") == [anchor("j-seg", 5, 4, "req-1"), completed("req-1")])
            #expect(seed.eventLog.segmentCount == 5)
        }
    }

    /// A log with no anchor — an older writer's, or an import's — is moved out of the way,
    /// and the journal starts over from the record's `last_seq`.
    @Test func aLogWithNoAnchorIsRotatedAway() async throws {
        try await withIsolatedStore {
            var seed = record("j-old")
            seed.lastSeq = 5
            try SessionStore.createSessionsDirectory()
            try Data((answer + "\n").utf8).write(to: ACPXPaths.sessionStreamPath("j-old"))
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt], writer: &writer, record: &seed)

            #expect(try lines("j-old", segment: 1) == [answer])
            #expect(try lines("j-old") == [anchor("j-old", 0, 5, nil), started("req-1"), prompt, completed("req-1")])
            #expect(seed.lastSeq == 6)
        }
    }

    /// A log that ends in part of a line — a write cut short — is moved out of the way too.
    @Test func aLogEndingInPartOfALineIsRotatedAway() async throws {
        try await withIsolatedStore {
            var seed = record("j-cut")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt], writer: &writer, record: &seed)
            let handle = try FileHandle(forWritingTo: ACPXPaths.sessionStreamPath("j-cut"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(#"{"jsonrpc":"2.0","met"#.utf8))
            try handle.close()

            var next = try SessionEventLogWriter.open(record: &seed)
            try turn("req-2", [prompt], writer: &next, record: &seed)
            #expect(try lines("j-cut", segment: 1).last == #"{"jsonrpc":"2.0","met"#)
            #expect(try lines("j-cut") == [anchor("j-cut", 3, 1, nil), started("req-2"), prompt, completed("req-2")])
        }
    }

    /// A writer goes on from where the journal left off, whatever the record says.
    @Test func aWriterGoesOnFromWhereTheJournalLeftOff() async throws {
        try await withIsolatedStore {
            var seed = record("j-on", maxSegmentBytes: 1)
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt, answer], writer: &writer, record: &seed)

            var stale = record("j-on", maxSegmentBytes: 1)
            var next = try SessionEventLogWriter.open(record: &stale)
            #expect(stale.lastSeq == 2)
            try next.beginTurn("req-2", into: &stale)
            // One record to a segment: the new one says four records and two messages came before.
            #expect(try lines("j-on") == [anchor("j-on", 4, 2, nil), started("req-2")])
        }
    }

    /// A turn an earlier writer started and never ended — it went down with it — is ended
    /// as of unknown outcome before the next one starts.
    @Test func aTurnLeftOpenIsEndedAsOfUnknownOutcome() async throws {
        try await withIsolatedStore {
            var seed = record("j-open")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try writer.beginTurn("req-1", into: &seed)
            try writer.append([body(prompt)], into: &seed)

            var next = try SessionEventLogWriter.open(record: &seed)
            try next.beginTurn("req-2", into: &seed)
            #expect(try lines("j-open").suffix(2) == [
                Self.schema + #""turn_result","request_id":"req-1","result":{"status":"failed","error":{"#
                    + #""message":"The previous owner ended without recording a settled result; the turn outcome is "#
                    + #"unknown.","detailCode":"WATCH_OUTCOME_UNKNOWN","retryable":false}}}"#,
                started("req-2")
            ])
        }
    }

    /// A journal that is not as a writer leaves it is refused, as acpx refuses it.
    @Test(arguments: [
        ("not json", "Invalid complete line in session journal"),
        (#"{"schema":"acpx.session.journal.v1","type":"turn_result","request_id":"other","#
            + #""result":{"status":"completed"}}"#, "Session journal result does not match the active request"),
        (#"{"schema":"acpx.session.journal.v1","type":"segment","record_id":"j-bad","sequence":0,"#
            + #""message_sequence":0,"request_id":null}"#, "Invalid session journal segment anchor"),
        (#"{"schema":"acpx.session.journal.v2"}"#, "Invalid record in session journal")
    ])
    func aCorruptJournalIsRefused(line: String, message: String) async throws {
        try await withIsolatedStore {
            var seed = record("j-bad")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try writer.beginTurn("req-1", into: &seed)
            let handle = try FileHandle(forWritingTo: ACPXPaths.sessionStreamPath("j-bad"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try handle.close()

            #expect(throws: SessionJournalError(code: "WATCH_JOURNAL_CORRUPT", message: message)) {
                _ = try SessionEventLogWriter.open(record: &seed)
            }
        }
    }

    /// A journal that cannot be written fails the turn: its start, or — once a write has
    /// failed — its end.
    @Test func aJournalThatCannotBeWrittenFailsTheTurn() async throws {
        try await withIsolatedStore {
            var seed = record("j-ro")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try turn("req-1", [prompt], writer: &writer, record: &seed)
            let path = ACPXPaths.sessionStreamPath("j-ro").path
            #expect(chmod(path, 0o400) == 0)
            defer { chmod(path, 0o600) }

            let persister = TurnPersister(record: seed, eventBuffer: WireBuffer(), requestId: "req-2")
            let failure = await #expect(throws: SessionJournalWriteError.self) { try await persister.beginTurn() }
            #expect(failure?.localizedDescription
                == "Session journal write failed: EACCES: permission denied, open '\(path)'")
            #expect(failure?.detailCode == "SESSION_JOURNAL_WRITE_FAILED")
        }
    }
}
