#if os(macOS) || os(Linux) || os(Windows)
import Foundation
@testable import SwiftACP
import Testing

/// Append-only ACP event log for in-process ``ACPAgent`` sessions (#334): filtered NDJSON
/// lines, crash-style partial tails left alone, and `eventLog: nil` doing no file I/O.
@Suite struct ACPEventLogWriterTests {
    private let prompt = #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{}}"#
    private let answer = #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#
    private let junk = #"{"hello":"world"}"#

    @Test func appendWritesEachACPMessageAsOneNDJSONLine() throws {
        try withTempLog { url in
            let writer = ACPEventLogWriter(url)
            try writer.append(Data(prompt.utf8))
            try writer.append(Data(answer.utf8))
            #expect(try lines(at: url) == [prompt, answer])
            // Byte-identical NDJSON: LF only — Windows text-mode open would write CRLF.
            #expect(try Data(contentsOf: url) == Data((prompt + "\n" + answer + "\n").utf8))
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("timestamps.ndjson").path))
        }
    }

    @Test func nonACPBodiesAreNotWritten() throws {
        try withTempLog { url in
            let writer = ACPEventLogWriter(url)
            try writer.append(Data(junk.utf8))
            try writer.append(Data(#"not json"#.utf8))
            try writer.append(Data(prompt.utf8))
            #expect(try lines(at: url) == [prompt])
        }
    }

    #if !os(Windows)
    @Test func rawOnlyLoggingSupportsANamedPipe() throws {
        try withTempLog { url in
            try #require(mkfifo(url.path, 0o600) == 0)
            // A nonblocking reader lets the writer open the FIFO and receives its bytes
            // once the per-message write closes. Seeking this target would fail with ESPIPE.
            let descriptor = Foundation.open(url.path, O_RDONLY | O_NONBLOCK)
            try #require(descriptor >= 0)
            let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? reader.close() }

            try ACPEventLogWriter(url).append(Data(prompt.utf8))

            #expect(try reader.readToEnd() == Data((prompt + "\n").utf8))
        }
    }
    #endif

    /// A write cut short leaves its partial last line for the reader — this writer has
    /// no rotation or recovery that would discard it.
    @Test func aPartialLastLineIsLeftForTheReader() throws {
        try withTempLog { url in
            let writer = ACPEventLogWriter(url)
            try writer.append(Data(prompt.utf8))
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(#"{"jsonrpc":"2.0","met"#.utf8))
            try handle.close()

            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text == prompt + "\n" + #"{"jsonrpc":"2.0","met"#)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func eventLogNilCreatesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-event-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("events.ndjson")

        let overrides = try #require(mockOverride())
        let agent = try await ACPAgent.launch(
            agent: "mock", cwd: NSTemporaryDirectory(), permission: .approveAll,
            inheritStderr: false, overrides: overrides, eventLog: nil)
        _ = try await agent.newSession()
        try await agent.close()
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(.enabled(if: mockPythonAvailable))
    func eventLogAppendsFromHandshakeOnward() async throws {
        try await withTempLog { url in
            let overrides = try #require(mockOverride())
            let agent = try await ACPAgent.launch(
                agent: "mock", cwd: NSTemporaryDirectory(), permission: .approveAll,
                inheritStderr: false, overrides: overrides, eventLog: url)
            _ = try await agent.newSession()
            try await agent.close()

            let written = try lines(at: url)
            #expect(!written.isEmpty)
            #expect(written.allSatisfy { line in
                guard let value = try? WireJSON.parse(line) else { return false }
                return WireJSON.isACPMessage(value)
            })
            #expect(written.contains { $0.contains(#""method":"initialize""#) })
        }
    }

    /// ``RawWireTap/set(_:)`` replaces the caller's callback, not the launch-time event log.
    @Test(.enabled(if: mockPythonAvailable))
    func replacingOnRawWireDoesNotStopEventLog() async throws {
        try await withTempLog { url in
            let overrides = try #require(mockOverride())
            let agent = try await ACPAgent.launch(
                agent: "mock", cwd: NSTemporaryDirectory(), permission: .approveAll,
                inheritStderr: false, overrides: overrides, eventLog: url)
            let before = try lines(at: url)
            #expect(before.contains { $0.contains(#""method":"initialize""#) })

            agent.rawWire.set(nil)
            _ = try await agent.newSession()
            try await agent.close()

            let after = try lines(at: url)
            #expect(after.count > before.count)
            #expect(after.contains { $0.contains(#""method":"session/new""#) })
        }
    }

    /// Both public launch entry points must index from initialize, independently of set(nil).
    @Test(.enabled(if: mockPythonAvailable), arguments: [false, true])
    func indexedLaunchIncludesHandshakeAndSurvivesSetNil(useHandlers: Bool) async throws {
        try await withTempLog { url in
            let index = url.appendingPathExtension("timestamps.ndjson")
            let overrides = try #require(mockOverride())
            let agent: ACPAgent
            if useHandlers {
                agent = try await ACPAgent.launch(
                    agent: "mock", cwd: NSTemporaryDirectory(), handlers: .standard(permission: .approveAll),
                    inheritStderr: false, overrides: overrides, eventLog: url, eventLogTimestampIndex: index)
            } else {
                agent = try await ACPAgent.launch(
                    agent: "mock", cwd: NSTemporaryDirectory(), permission: .approveAll,
                    inheritStderr: false, overrides: overrides, eventLog: url, eventLogTimestampIndex: index)
            }
            let before = try lines(at: index).count
            agent.rawWire.set(nil)
            _ = try await agent.newSession()
            try await agent.close()

            let records = try checkedIndex(raw: url, index: index)
            #expect(records.count > before)
            #expect(records.first?.direction == .outbound)
            #expect(try lines(at: url).first?.contains(#""method":"initialize""#) == true)
            #expect(records.contains { $0.direction == .inbound })
            #expect(records.allSatisfy { $0.direction != nil })
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func indexFailureDoesNotFailTransportOrRawLogging() async throws {
        try await withTempLog { url in
            let index = url.appendingPathExtension("timestamps.ndjson")
            try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
            let overrides = try #require(mockOverride())
            let agent = try await ACPAgent.launch(
                agent: "mock", cwd: NSTemporaryDirectory(), permission: .approveAll,
                inheritStderr: false, overrides: overrides, eventLog: url, eventLogTimestampIndex: index)
            _ = try await agent.newSession()
            try await agent.close()
            #expect(try lines(at: url).contains { $0.contains(#""method":"session/new""#) })
        }
    }

    @Test func concurrentCopiesAndObserverCallbacksKeepCompletePairs() throws {
        try withTempLog { url in
            let index = url.appendingPathExtension("timestamps.ndjson")
            let writer = ACPEventLogWriter(url, timestampIndex: index)
            let copy = writer
            let observer = writer.observer
            let tap = RawWireTap()
            tap.setEventLog(writer.timestampedObserver)
            let body = Data(prompt.utf8)
            DispatchQueue.concurrentPerform(iterations: 120) { iteration in
                switch iteration % 4 {
                case 0: try? writer.append(body)
                case 1: try? copy.append(body)
                case 2: observer(.inbound, body)
                default: tap.observe(.outbound, body)
                }
            }
            let records = try checkedIndex(raw: url, index: index)
            let raw = try Data(contentsOf: url)
            #expect(records.count == 120)
            #expect(raw == Data(String(repeating: prompt + "\n", count: 120).utf8))
        }
    }

    /// Direct unit coverage of the side channel: ``set(_:)`` must not clear ``setEventLog``.
    @Test func setDoesNotClearEventLogObserver() throws {
        try withTempLog { url in
            let tap = RawWireTap { _, _ in }
            tap.setEventLog(ACPEventLogWriter(url).timestampedObserver)
            tap.set(nil)
            tap.observe(.outbound, Data(prompt.utf8))
            let written = try lines(at: url)
            #expect(written == [prompt])
        }
    }

    private func mockOverride() -> [String: String]? {
        guard let python = mockPython else { return nil }
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mock-agent.py")
        guard FileManager.default.fileExists(atPath: fixtures.path) else { return nil }
        return ["mock": "'\(python)' '\(fixtures.path)'"]
    }

    private func withTempLog(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-event-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("events.ndjson"))
    }

    private func withTempLog(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-event-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory.appendingPathComponent("events.ndjson"))
    }

    private func lines(at url: URL) throws -> [String] {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

/// Validate every record against physical raw bytes, including LF and cumulative offsets.
func checkedIndex(raw: URL, index: URL) throws -> [ACPEventLogIndexRecord] {
    let bytes = try Data(contentsOf: raw)
    let metadata = try Data(contentsOf: index)
    #expect(metadata.last == 0x0A)
    let records = try metadata.split(separator: 0x0A).map {
        try JSONDecoder().decode(ACPEventLogIndexRecord.self, from: Data($0))
    }
    var offset: UInt64 = 0
    for record in records {
        #expect(record.version == 1)
        #expect(record.offset == offset)
        let end = record.offset + record.length
        try #require(end <= UInt64(bytes.count))
        let line = bytes.subdata(in: Int(record.offset)..<Int(end))
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(ACPEventLogIndexRecord.checksum(line) == record.crc32)
        offset = end
    }
    #expect(offset == UInt64(bytes.count))
    return records
}
#endif
