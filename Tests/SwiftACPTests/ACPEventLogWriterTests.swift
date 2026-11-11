#if os(macOS) || os(Linux)
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

    /// Direct unit coverage of the side channel: ``set(_:)`` must not clear ``setEventLog``.
    @Test func setDoesNotClearEventLogObserver() throws {
        try withTempLog { url in
            let tap = RawWireTap { _, _ in }
            tap.setEventLog(ACPEventLogWriter(url).observer)
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
#endif
