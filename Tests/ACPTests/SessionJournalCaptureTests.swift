@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// A journal is read as one capture, as acpx 0.19.3 reads it (#753): a read the segments
/// moved under is read again, and a page moves the watch's reader on only once it is had.
@Suite(.serialized) struct SessionJournalCaptureTests {
    private let prompt = #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{}}"#
    private let answer = #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#

    private func anchor(_ id: String, _ sequence: Int) -> String {
        #"{"schema":"acpx.session.journal.v1","type":"segment","record_id":"\#(id)","sequence":\#(sequence),"#
            + #""message_sequence":\#(sequence),"request_id":null}"# + "\n"
    }

    /// Write the journal of `id`: `segments` oldest first, the last the active one.
    private func journal(_ id: String, _ segments: [String]) throws {
        let active = ACPXPaths.sessionStreamPath(id)
        try FileManager.default.createDirectory(
            at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (index, contents) in segments.enumerated() {
            let number = segments.count - 1 - index
            let url = number == 0 ? active : ACPXPaths.sessionStreamSegmentPath(id, segment: number)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// What `id`'s journal holds: seg 1 with two messages, the active segment with one.
    private func twoSegments(_ id: String) throws {
        try journal(id, [anchor(id, 0) + prompt + "\n" + answer + "\n", anchor(id, 2) + prompt + "\n"])
    }

    /// Rotation, as the writer does it: each segment one further back, and a new active one.
    private func rotate(_ id: String, active contents: String) throws {
        let manager = FileManager.default
        let first = ACPXPaths.sessionStreamSegmentPath(id, segment: 1)
        if manager.fileExists(atPath: first.path) {
            try manager.moveItem(at: first, to: ACPXPaths.sessionStreamSegmentPath(id, segment: 2))
        }
        try manager.moveItem(at: ACPXPaths.sessionStreamPath(id), to: first)
        try contents.write(to: ACPXPaths.sessionStreamPath(id), atomically: true, encoding: .utf8)
    }

    /// Runs `body` once, on the first capture only.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let body: @Sendable () throws -> Void
        init(_ body: @escaping @Sendable () throws -> Void) { self.body = body }
        func callAsFunction() throws {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { try body() }
        }
    }

    /// A page that fails leaves the reader where the last page did: the next delivers what
    /// the failed one read before failing, where it was skipped.
    @Test func aFailedPageLeavesTheReaderWhereItWas() async throws {
        try await withIsolatedStore {
            try twoSegments("c-failed")
            let active = ACPXPaths.sessionStreamPath("c-failed")
            let intact = try Data(contentsOf: active).count
            let handle = try FileHandle(forWritingTo: active)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("not json\n".utf8))

            let reader = SessionJournal.Reader(recordId: "c-failed", maxSegments: 5)
            await #expect(throws: SessionJournalError.self) { _ = try await reader.read(after: -1, maxBytes: 1 << 20) }
            try handle.truncate(atOffset: UInt64(intact))
            try handle.close()
            let page = try await reader.read(after: -1, maxBytes: 1 << 20)
            #expect(page.events.map(\.sequence) == [1, 2, 3])
        }
    }

    /// So does a page called off once its capture is read.
    @Test func aPageCalledOffLeavesTheReaderWhereItWas() async throws {
        try await withIsolatedStore {
            try twoSegments("c-called-off")
            // One reader for both pages, each in a task of its own; they take turns.
            nonisolated(unsafe) let reader = SessionJournal.Reader(recordId: "c-called-off", maxSegments: 5)
            let calledOff = Task {
                try await SessionJournal.$afterCapture.withValue(
                    { withUnsafeCurrentTask { $0?.cancel() } },
                    operation: { try await reader.read(after: -1, maxBytes: 1 << 20) })
            }
            await #expect(throws: CancellationError.self) { _ = try await calledOff.value }
            let page = try await reader.read(after: -1, maxBytes: 1 << 20)
            #expect(page.events.map(\.sequence) == [1, 2, 3])
        }
    }

    /// Segments rotation moves while they are read are read again: the export has every
    /// message once, the new active segment's too, and the tail is where the journal ends.
    @Test func aCaptureRotationMovedIsReadAgain() async throws {
        try await withIsolatedStore {
            try twoSegments("c-rotated")
            let rotation = Once { try rotate("c-rotated", active: anchor("c-rotated", 3) + answer + "\n") }
            let now = nowISO()
            var record = SessionRecord(
                acpxRecordId: "c-rotated", acpSessionId: "c-rotated", agentCommand: "codex", cwd: "/tmp",
                createdAt: now, lastUsedAt: now)
            record.eventLog.maxSegments = 5
            let history = try SessionJournal.$afterCapture.withValue(
                { try rotation() }, operation: { try SessionArchive.history(of: record) })
            #expect(history.count == 4)

            try twoSegments("c-rotated-tail")
            let tailRotation = Once {
                try rotate("c-rotated-tail", active: anchor("c-rotated-tail", 3) + answer + "\n")
            }
            let tail = try SessionJournal.$afterCapture.withValue(
                { try tailRotation() },
                operation: { try SessionJournal.readTail(recordId: "c-rotated-tail", maxSegments: 5) })
            #expect(tail.sequence == 4)
        }
    }

    /// A journal that only looks corrupt while rotation moves it is read again, not failed:
    /// here the capture finds a gap between the segments, which the rotation closes.
    @Test func aJournalThatOnlyLooksCorruptMidRotationIsReadAgain() async throws {
        try await withIsolatedStore {
            try journal("c-gap", [anchor("c-gap", 0) + prompt + "\n", anchor("c-gap", 5) + answer + "\n"])
            // Written beside the old file and renamed over it, so it is another file.
            let closeTheGap = Once {
                try (anchor("c-gap", 1) + answer + "\n").write(
                    to: ACPXPaths.sessionStreamPath("c-gap"), atomically: true, encoding: .utf8)
            }
            let reader = SessionJournal.Reader(recordId: "c-gap", maxSegments: 5)
            let page = try await SessionJournal.$afterCapture.withValue(
                { try closeTheGap() }, operation: { try await reader.read(after: -1, maxBytes: 1 << 20) })
            #expect(page.events.map(\.sequence) == [1, 2])
        }
    }
}
