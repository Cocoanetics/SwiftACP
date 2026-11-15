#if os(macOS) || os(Linux) || os(Windows)
import Foundation
@testable import SwiftACP
import Testing

/// The typed reader over ``ACPEventLogWriter``'s NDJSON (#335): prompts, their answers and
/// `session/update`s in file order, other ACP messages left out, a partial tail skipped.
@Suite struct ACPEventLogReaderTests {
    private let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}"#
    private let prompt =
        #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"s1","#
        + #""prompt":[{"type":"text","text":"Hi"}]}}"#
    private let chunk =
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":"#
        + #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}"#
    /// The agent's own request, with the same id as the client's prompt.
    private let permission =
        #"{"jsonrpc":"2.0","id":1,"method":"session/request_permission","params":{"sessionId":"s1"}}"#
    private let permissionAnswer = #"{"jsonrpc":"2.0","id":1,"result":{"outcome":{"outcome":"cancelled"}}}"#
    private let answer = #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#

    @Test func eventLogRoundTripPromptUpdatesAndResponse() throws {
        try withTempLog { url in
            let writer = ACPEventLogWriter(url)
            for line in [initialize, prompt, chunk, permission, permissionAnswer, chunk, answer] {
                try writer.append(Data(line.utf8))
            }
            let entries = try ACPEventLogReader(url).entries()
            #expect(entries.count == 4)
            guard entries.count == 4 else { return }

            guard case .prompt(let promptId, let request) = entries[0] else {
                Issue.record("expected a prompt, got \(entries[0])")
                return
            }
            #expect(promptId == .integer(1))
            #expect(request.sessionId == "s1")
            for entry in entries[1...2] {
                guard case .update(let notification) = entry, case .agentMessageChunk = notification.update else {
                    Issue.record("expected an agent_message_chunk update, got \(entry)")
                    continue
                }
                #expect(notification.sessionId == "s1")
                #expect(notification.rawUpdate?["sessionUpdate"] == .text("agent_message_chunk"))
            }
            guard case .promptResponse(let answerId, let response) = entries[3] else {
                Issue.record("expected the prompt's response, got \(entries[3])")
                return
            }
            #expect(answerId == .integer(1))
            #expect(response.stopReason == .endTurn)
        }
    }

    @Test func timestampedWriterRoundTripIncludesEveryRawMessage() throws {
        try withTempLog { url in
            let indexURL = url.appendingPathExtension("timestamps.ndjson")
            let writer = ACPEventLogWriter(url, timestampIndex: indexURL)
            let bodies = [initialize, prompt, chunk, permission, permissionAnswer, chunk, answer]
            // Deliberately equal and backwards times: file order is the only ordering.
            let times = [7, 7, 6, 8, 5, 4, 3].map { knownTime.addingTimeInterval(Double($0)) }
            let directions: [ACPEventLogDirection?] = [.outbound, .outbound, .inbound, .inbound,
                                                      .outbound, nil, .inbound]
            for index in bodies.indices {
                try writer.append(Data(bodies[index].utf8), timestamp: times[index], direction: directions[index])
            }
            let reader = ACPEventLogReader(url, timestampIndex: indexURL)
            let raw = try reader.messagesWithTimes()
            #expect(raw.map(\.message) == bodies.compactMap { WireJSON(parsing: $0) })
            #expect(raw.map(\.timestamp) == times.map(Optional.some))
            #expect(raw.map(\.direction) == directions)
            var offset: UInt64 = 0
            for message in raw {
                #expect(message.byteOffset == offset)
                offset += UInt64(message.message.stringified.utf8.count + 1)
            }
            let typed = try reader.entriesWithTimes()
            let selected = [1, 2, 5, 6]
            #expect(typed.map(\.byteOffset) == selected.map { raw[$0].byteOffset })
            #expect(typed.map(\.timestamp) == selected.map { times[$0] })
            #expect(typed.map(\.direction) == selected.map { directions[$0] })
            #expect(typed.map { describe($0.entry) } == (try reader.entries()).map(describe))
            let data = try Data(contentsOf: url)
            let index = try Data(contentsOf: indexURL)
            #expect(ACPEventLogReader.messagesWithTimes(in: data, timestampIndex: index).map(\.timestamp)
                    == raw.map(\.timestamp))
            #expect(ACPEventLogReader.entriesWithTimes(in: data, timestampIndex: index).map(\.byteOffset)
                    == typed.map(\.byteOffset))
        }
    }

    @Test func physicalOffsetsSurviveUTF8CRLFBlanksJunkAndDuplicateBodies() throws {
        let unicode = chunk.replacingOccurrences(of: "Hello", with: "Grüß dich 👋")
        let lines = ["\n", "junk\n", "{\"other\":true}\n", "{broken\n", prompt + "\r\n",
                     unicode + "\r\n", "\r\n", unicode + "\n", answer + "\n"]
        let data = Data(lines.joined().utf8)
        let index = try makeIndex(lines)
        let raw = ACPEventLogReader.messagesWithTimes(in: data, timestampIndex: index)
        let selected = [4, 5, 7, 8]
        #expect(raw.count == selected.count)
        #expect(raw.map(\.byteOffset) == selected.map { UInt64(lines.prefix($0).joined().utf8.count) })
        #expect(raw.map(\.timestamp) == selected.map { knownTime.addingTimeInterval(Double($0)) })
        #expect(raw.map(\.direction) == Array(repeating: .inbound, count: 4))
        #expect(ACPEventLogReader.entriesWithTimes(in: data, timestampIndex: index).count == 4)
        // Data slices need not start at zero; offsets remain relative to the snapshot.
        let padded = Data("prefix".utf8) + data
        #expect(ACPEventLogReader.messagesWithTimes(in: padded.dropFirst(6), timestampIndex: index)
            .map(\.byteOffset) == raw.map(\.byteOffset))
    }

    @Test func missingEmptyShortSparseAndTornIndexesDoNotShiftMetadata() throws {
        let lines = [prompt + "\n", chunk + "\n", answer + "\n"]
        let data = Data(lines.joined().utf8)
        let records = try indexLines(lines)
        let cases: [(Data?, [Bool])] = [
            (nil, [false, false, false]), (Data(), [false, false, false]),
            (records[0], [true, false, false]),
            (records[0] + records[2], [true, false, true]),
            (records[0] + Data(records[1].prefix(20)), [true, false, false]),
            // Even valid JSON in an unterminated sidecar tail is not committed.
            (records[0] + records[1].dropLast(), [true, false, false]),
            (records[0] + Data("{broken\n\n".utf8) + records[2], [true, false, true])
        ]
        for (index, expected) in cases {
            let raw = ACPEventLogReader.messagesWithTimes(in: data, timestampIndex: index)
            #expect(raw.count == 3)
            #expect(raw.map { $0.timestamp != nil } == expected)
            #expect(raw.map { $0.direction != nil } == expected)
            #expect(ACPEventLogReader.entriesWithTimes(in: data, timestampIndex: index).count == 3)
        }
    }

    @Test func invalidIndexRecordsOnlyInvalidateTheirExactOffset() throws {
        let lines = [prompt + "\n", chunk + "\n", answer + "\n"]
        let records = try indexLines(lines)
        let changes: [(String, WireJSON)] = [
            ("version", .number(2)), ("length", .number(0)), ("length", .number(1)),
            ("length", .text("18446744073709551615")), ("crc32", .number(0)),
            ("timestamp", .text("2023-11-14T22:13:20Z")),
            ("timestamp", .text("2023-11-14T23:13:20.125+01:00")),
            ("timestamp", .text("2023-02-30T22:13:20.125Z")),
            ("timestamp", .text("nonsense")), ("direction", .text("sideways"))
        ]
        for (key, value) in changes {
            let record = try #require(WireJSON(parsing: records[1])).replacing(key, with: value)
            let index = records[0] + Data((record.stringified + "\n").utf8) + records[2]
            let raw = ACPEventLogReader.messagesWithTimes(in: Data(lines.joined().utf8), timestampIndex: index)
            #expect(raw.map { $0.timestamp != nil } == [true, false, true])
            #expect(raw.map { $0.direction != nil } == [true, false, true])
        }
        // A byte change with the same line length invalidates only its checksum.
        let stale = Data(lines.joined().replacingOccurrences(of: "Hello", with: "Hallo").utf8)
        #expect(ACPEventLogReader.messagesWithTimes(in: stale, timestampIndex: records.reduce(Data(), +))
            .map { $0.timestamp != nil } == [true, false, true])
    }

    @Test func identicalDuplicatesDeduplicateAndConflictsStayInvalid() throws {
        let lines = [prompt + "\n", chunk + "\n", answer + "\n"]
        let records = try indexLines(lines)
        let data = Data(lines.joined().utf8)
        let identical = records.reduce(Data(), +) + records[1]
        #expect(ACPEventLogReader.messagesWithTimes(in: data, timestampIndex: identical)
            .allSatisfy { $0.timestamp != nil })
        for key in ["timestamp", "direction", "crc32", "version"] {
            let original = try #require(WireJSON(parsing: records[1]))
            let value: WireJSON
            switch key {
            case "timestamp": value = .text("2020-01-01T00:00:00.000Z")
            case "direction": value = .text("outbound")
            default: value = .number(99)
            }
            let conflict = original.replacing(key, with: value)
            let changed = Data((conflict.stringified + "\n").utf8)
            for index in [identical + changed + records[1], changed + identical] {
                #expect(ACPEventLogReader.messagesWithTimes(in: data, timestampIndex: index)
                    .map { $0.timestamp != nil } == [true, false, true])
            }
        }
    }

    @Test func boundsLineBoundariesAndIndexAheadOfSnapshotAreValidated() throws {
        let lines = [prompt + "\n", chunk + "\n", answer + "\n"]
        let records = try indexLines(lines)
        let snapshot = Data(lines.prefix(2).joined().utf8)
        #expect(ACPEventLogReader.messagesWithTimes(in: snapshot, timestampIndex: records.reduce(Data(), +))
            .map { $0.timestamp != nil } == [true, true])
        let invalid = [
            ACPEventLogIndexRecord(offset: 1, bytes: Data(lines[0].utf8).dropFirst(),
                                   timestamp: knownTime, direction: .inbound),
            ACPEventLogIndexRecord(offset: 0, bytes: snapshot, timestamp: knownTime, direction: .inbound),
            ACPEventLogIndexRecord(offset: UInt64.max, bytes: snapshot,
                                   timestamp: knownTime, direction: .inbound)
        ]
        for record in invalid {
            let index = try record.line() + records[1]
            let raw = ACPEventLogReader.messagesWithTimes(in: snapshot, timestampIndex: index)
            #expect(raw.map { $0.timestamp != nil } == [false, true])
        }
    }

    @Test func partialAndParseableUnterminatedRawTails() throws {
        let lines = [prompt + "\n", chunk + "\n", answer + "\n"]
        let index = try makeIndex(lines)
        for tail in [String(answer.prefix(20)), answer] {
            let data = Data((lines[0] + lines[1] + tail).utf8)
            let raw = ACPEventLogReader.messagesWithTimes(in: data, timestampIndex: index)
            #expect(raw.count == (tail == answer ? 3 : 2))
            #expect(raw.prefix(2).allSatisfy { $0.timestamp != nil })
            if tail == answer {
                #expect(raw.last?.timestamp == nil)
                #expect(raw.last?.direction == nil)
            }
            #expect(ACPEventLogReader.entriesWithTimes(in: data, timestampIndex: index).count == raw.count)
        }
    }

    @Test func unreadableAndAbsentIndexesLeaveRawAndLegacyReplayUsable() throws {
        try withTempLog { url in
            try ndjson([prompt, chunk, answer]).write(to: url)
            for index in [url.appendingPathExtension("missing"), url.deletingLastPathComponent()] {
                let reader = ACPEventLogReader(url, timestampIndex: index)
                #expect(try reader.messagesWithTimes().allSatisfy { $0.timestamp == nil && $0.direction == nil })
                #expect(try reader.entriesWithTimes().count == 3)
                #expect(try reader.entries().count == 3)
            }
            #expect(try ACPEventLogReader(url).messagesWithTimes().allSatisfy { $0.timestamp == nil })
        }
    }

    @Test func timedReplayKeepsAllLegacyTypedCasesAndSameIDCorrelation() throws {
        let error = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}"#
        let vendor = #"{"jsonrpc":"2.0","id":1,"method":"_vendor/foo","params":{}}"#
        let sequences = [
            [prompt, chunk, answer], [prompt, error],
            [prompt, permission, answer, permissionAnswer],
            [prompt, permission, error, permissionAnswer],
            [prompt, permission, error, answer], [prompt, vendor, error, answer]
        ]
        for sequence in sequences {
            let lines = sequence.map { $0 + "\n" }
            let data = Data(lines.joined().utf8)
            let legacy = ACPEventLogReader.entries(in: data).map(describe)
            for index in [nil, try makeIndex(lines)] {
                let typed = ACPEventLogReader.entriesWithTimes(in: data, timestampIndex: index)
                #expect(typed.map { describe($0.entry) } == legacy)
                // Deliberately label every message inbound: metadata cannot reclassify it.
                #expect(typed.allSatisfy { $0.direction == (index == nil ? nil : .inbound) })
                #expect(typed.map(\.byteOffset) == typed.map(\.byteOffset).sorted())
            }
        }
    }

    @Test func aPromptAnsweredWithAnErrorReplaysTheError() {
        let error = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}"#
        let entries = ACPEventLogReader.entries(in: Data((prompt + "\n" + error + "\n").utf8))
        #expect(entries.count == 2)
        guard entries.count == 2, case .promptError(let id, let body) = entries[1] else {
            Issue.record("expected the prompt's error, got \(entries)")
            return
        }
        #expect(id == .integer(1))
        #expect(body.code == -32603)
        #expect(body.message == "boom")
    }

    /// The prompt answered while the agent's same-id permission request is still open: the
    /// answer is the prompt's, and the permission's cancellation after it is not (#337).
    @Test func aPromptAnsweredBeforeTheAgentsSameIdRequestKeepsItsAnswer() {
        let entries = ACPEventLogReader.entries(in: ndjson([prompt, permission, answer, permissionAnswer]))
        #expect(entries.count == 2)
        guard entries.count == 2, case .promptResponse(let id, let response) = entries[1] else {
            Issue.record("expected the prompt's response, got \(entries)")
            return
        }
        #expect(id == .integer(1))
        #expect(response.stopReason == .endTurn)
    }

    /// An error with the id open on both sides: the prompt's when what answers the other
    /// request after it is no prompt response, the agent's request's when it is.
    @Test func anErrorOpenOnBothSidesGoesByTheAnswerAfterIt() {
        let error = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}"#
        let failed = ACPEventLogReader.entries(in: ndjson([prompt, permission, error, permissionAnswer]))
        #expect(failed.count == 2)
        if failed.count == 2, case .promptError = failed[1] {} else {
            Issue.record("expected the prompt's error, got \(failed)")
        }

        let readFailed = ACPEventLogReader.entries(in: ndjson([prompt, permission, error, answer]))
        #expect(readFailed.count == 2)
        if readFailed.count == 2, case .promptResponse = readFailed[1] {} else {
            Issue.record("expected the prompt's response, got \(readFailed)")
        }
    }

    /// An agent request of a method the reader does not know, with the open prompt's id,
    /// is the agent's: it neither replaces the prompt nor takes the prompt's answer.
    @Test func anUnknownRequestWithThePromptsIdIsTheAgents() {
        let vendor = #"{"jsonrpc":"2.0","id":1,"method":"_vendor/foo","params":{}}"#
        let notFound = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#
        let entries = ACPEventLogReader.entries(in: ndjson([prompt, vendor, notFound, answer]))
        #expect(entries.count == 2)
        if entries.count == 2, case .promptResponse(let id, _) = entries[1] {
            #expect(id == .integer(1))
        } else {
            Issue.record("expected the prompt's response, got \(entries)")
        }
    }

    @Test func eventLogReaderToleratesPartialLastLine() throws {
        try withTempLog { url in
            let writer = ACPEventLogWriter(url)
            try writer.append(Data(prompt.utf8))
            try writer.append(Data(chunk.utf8))
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(answer.utf8.prefix(20)))
            try handle.close()

            let entries = try ACPEventLogReader(url).entries()
            #expect(entries.count == 2)
            guard entries.count == 2, case .prompt = entries[0], case .update = entries[1] else {
                Issue.record("expected the prompt and its update, got \(entries)")
                return
            }
        }
    }

    @Test func aMissingLogThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { _ = try ACPEventLogReader(url).entries() }
        #expect(throws: (any Error).self) { _ = try ACPEventLogReader(url).entriesWithTimes() }
        #expect(throws: (any Error).self) { _ = try ACPEventLogReader(url).messagesWithTimes() }
    }

    private func ndjson(_ lines: [String]) -> Data {
        Data(lines.map { $0 + "\n" }.joined().utf8)
    }

    private var knownTime: Date { Date(timeIntervalSince1970: 1_700_000_000.125) }

    private func indexLines(_ lines: [String]) throws -> [Data] {
        var offset: UInt64 = 0
        return try lines.enumerated().map { index, line in
            let bytes = Data(line.utf8)
            defer { offset += UInt64(bytes.count) }
            return try ACPEventLogIndexRecord(offset: offset, bytes: bytes,
                                             timestamp: knownTime.addingTimeInterval(Double(index)),
                                             direction: .inbound).line()
        }
    }

    private func makeIndex(_ lines: [String]) throws -> Data {
        try indexLines(lines).reduce(Data(), +)
    }

    private func describe(_ entry: ACPEventLogEntry) -> String {
        String(describing: entry)
    }

    private func withTempLog(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-event-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("events.ndjson"))
    }
}
#endif
