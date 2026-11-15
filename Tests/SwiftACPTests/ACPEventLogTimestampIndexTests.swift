#if os(macOS) || os(Linux) || os(Windows)
import Foundation
@testable import SwiftACP
import Testing

@Suite struct ACPEventLogTimestampIndexTests {
    private let prompt = #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"text":"Grüße 🌍"}}"#
    private let knownTime = Date(timeIntervalSince1970: 1_700_000_000.125)

    @Test func exactFormatTimesDirectionsAndUTF8Bytes() throws {
        try withPair { raw, index in
            let writer = ACPEventLogWriter(raw, timestampIndex: index)
            let body = Data(prompt.utf8)
            try writer.append(body, timestamp: knownTime, direction: .outbound)
            try writer.append(body, timestamp: knownTime.addingTimeInterval(-1), direction: .inbound)
            try writer.append(body, timestamp: knownTime)
            #expect(try Data(contentsOf: raw) == Data(String(repeating: prompt + "\n", count: 3).utf8))
            let records = try checkedIndex(raw: raw, index: index)
            #expect(records.map(\.direction) == [.outbound, .inbound, nil])
            #expect(records.map(\.timestamp) == [
                "2023-11-14T22:13:20.125Z", "2023-11-14T22:13:19.125Z", "2023-11-14T22:13:20.125Z"
            ])
            #expect(records[1].offset == UInt64(prompt.utf8.count + 1))
            let serialized = try String(contentsOf: index, encoding: .utf8).split(separator: "\n")
            #expect(!serialized[2].contains("direction"))
            let object = try #require(JSONSerialization.jsonObject(with: Data(serialized[0].utf8)) as? [String: Any])
            #expect(Set(object.keys) == ["version", "offset", "length", "crc32", "timestamp", "direction"])
            #expect(object["crc32"] is NSNumber)
        }
        #expect(ACPEventLogIndexRecord.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ACPEventLogIndexRecord.checksum(Data()) == 0)
    }

    @Test func nonACPInputCreatesNeitherFile() throws {
        try withPair { raw, index in
            let writer = ACPEventLogWriter(raw, timestampIndex: index)
            for input in ["not json", #"{"hello":"world"}"#, "[]"] {
                try writer.append(Data(input.utf8))
            }
            #expect(!FileManager.default.fileExists(atPath: raw.path))
            #expect(!FileManager.default.fileExists(atPath: index.path))
            try writer.append(Data(prompt.utf8))
            #expect(try checkedIndex(raw: raw, index: index).count == 1)
        }
    }

    @Test func reopenUsesPhysicalEndIncludingLegacyNonACPLines() throws {
        try withPair { raw, index in
            let legacy = Data(("\nnot JSON\n{}\r\n" + prompt + "\n").utf8)
            try legacy.write(to: raw)
            try ACPEventLogWriter(raw, timestampIndex: index).append(Data(prompt.utf8))
            try ACPEventLogWriter(raw, timestampIndex: index).append(Data(prompt.utf8))
            let records = try readIndex(index)
            #expect(records.map(\.offset) == [UInt64(legacy.count), UInt64(legacy.count + prompt.utf8.count + 1)])
            #expect(try Data(contentsOf: raw) == legacy + Data(String(repeating: prompt + "\n", count: 2).utf8))
        }
    }

    @Test func tornRawTailIsPreservedAndOnlyNextWholeLineIsIndexed() throws {
        try withPair { raw, index in
            let tail = Data(#"{"jsonrpc":"2.0","met"#.utf8)
            try tail.write(to: raw)
            let writer = ACPEventLogWriter(raw, timestampIndex: index)
            try writer.append(Data(prompt.utf8))
            #expect(!FileManager.default.fileExists(atPath: index.path))
            try writer.append(Data(prompt.utf8))
            let records = try readIndex(index)
            #expect(records.count == 1)
            #expect(records.first?.offset == UInt64(tail.count + prompt.utf8.count + 1))
            #expect(try Data(contentsOf: raw) == tail + Data(String(repeating: prompt + "\n", count: 2).utf8))
        }
    }

    @Test func tornIndexTailIsSeparatedWithoutRepair() throws {
        try withPair { raw, index in
            let tail = Data(#"{"version":1,"off"#.utf8)
            try tail.write(to: index)
            try ACPEventLogWriter(raw, timestampIndex: index).append(Data(prompt.utf8))
            let bytes = try Data(contentsOf: index)
            #expect(bytes.starts(with: tail + Data([0x0A])))
            let record = try JSONDecoder().decode(
                ACPEventLogIndexRecord.self, from: Data(try #require(bytes.split(separator: 0x0A).last)))
            #expect(record.offset == 0)
            #expect(record.length == UInt64(prompt.utf8.count + 1))
        }
    }

    @Test func rawOpenFailureCreatesNoIndex() throws {
        try withPair { raw, index in
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) {
                try ACPEventLogWriter(raw, timestampIndex: index).append(Data(prompt.utf8))
            }
            #expect(!FileManager.default.fileExists(atPath: index.path))
        }
    }

    @Test func sidecarOpenFailurePreservesRawAndObserverKeepsLogging() throws {
        try withPair { raw, index in
            try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
            let writer = ACPEventLogWriter(raw, timestampIndex: index)
            #expect(throws: (any Error).self) { try writer.append(Data(prompt.utf8)) }
            writer.observer(.inbound, Data(prompt.utf8))
            #expect(try Data(contentsOf: raw) == Data(String(repeating: prompt + "\n", count: 2).utf8))
        }
    }

    @Test func shortWritesAreCompletedForBothFiles() throws {
        try withPair { raw, index in
            let writer = ACPEventLogWriter(raw, timestampIndex: index) { descriptor, buffer in
                try ACPEventLogWriter.write(descriptor, UnsafeRawBufferPointer(rebasing: buffer.prefix(3)))
            }
            try writer.append(Data(prompt.utf8))
            #expect(try checkedIndex(raw: raw, index: index).count == 1)
        }
    }

    @Test(arguments: [false, true])
    func partialWriteFailureNeverIndexesIncompleteRawAndCanContinue(failIndex: Bool) throws {
        try withPair { raw, index in
            let writes = FailingWrites(failIndex: failIndex)
            let writer = ACPEventLogWriter(raw, timestampIndex: index, write: writes.write)
            #expect(throws: ACPEventLogWriter.Failure.self) { try writer.append(Data(prompt.utf8)) }
            if failIndex {
                #expect(try Data(contentsOf: raw) == Data((prompt + "\n").utf8))
                #expect(try Data(contentsOf: index).count == 3)
            } else {
                #expect(try Data(contentsOf: raw) == Data(prompt.utf8.prefix(3)))
                #expect(!FileManager.default.fileExists(atPath: index.path))
            }
            // The same shared writer recovers: raw tails stay untouched; sidecar tails get LF.
            try writer.append(Data(prompt.utf8))
            try writer.append(Data(prompt.utf8))
            let parts = try Data(contentsOf: index).split(separator: 0x0A)
            let records = parts.compactMap { try? JSONDecoder().decode(ACPEventLogIndexRecord.self, from: Data($0)) }
            #expect(records.count == (failIndex ? 2 : 1))
            #expect(records.last?.offset == UInt64((failIndex ? 0 : 3) + (prompt.utf8.count + 1) * (failIndex ? 2 : 1)))
        }
    }

    @Test func zeroByteWriteFailsInsteadOfLooping() throws {
        try withPair { raw, index in
            let writer = ACPEventLogWriter(raw, timestampIndex: index) { _, _ in 0 }
            #expect(throws: ACPEventLogWriter.Failure.self) { try writer.append(Data(prompt.utf8)) }
            let bytes = try Data(contentsOf: raw)
            #expect(bytes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: index.path))
        }
    }

    @Test func timestampIsCapturedBeforeCallerAndSuppressionStillApplies() throws {
        try withPair { raw, index in
            let times = CallbackTimes()
            let tap = RawWireTap { _, _ in times.enter() }
            let writer = ACPEventLogWriter(raw, timestampIndex: index)
            tap.setEventLog { direction, body, time in
                #expect(time <= times.date)
                writer.timestampedObserver(direction, body, time)
            }
            tap.observe(.outbound, Data(prompt.utf8))
            tap.setEventLog(writer.timestampedObserver)
            tap.beginSuppressingReplay(of: "quiet")
            let update = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"quiet"}}"#
            tap.observe(.inbound, Data(update.utf8))
            tap.set(nil)
            tap.endSuppressingReplay(of: "quiet")
            tap.observe(.inbound, Data(update.utf8))
            let records = try checkedIndex(raw: raw, index: index)
            #expect(records.count == 2)
        }
    }

    @Test func indexFormatRetainsFullUInt64Offsets() throws {
        let record = ACPEventLogIndexRecord(
            offset: UInt64.max - 100, bytes: Data([0x0A]), timestamp: knownTime, direction: nil)
        #expect(try JSONDecoder().decode(ACPEventLogIndexRecord.self, from: record.line()) == record)
    }

    @Test func invalidLaunchPairsAreRejectedBeforeResolvingOrSpawningAgent() async throws {
        try await withPair { raw, index in
            let error = await #expect(throws: ACPEventLogWriter.Failure.self) {
                _ = try await ACPAgent.launch(
                    agent: "does-not-exist-339", permission: .approveAll, eventLogTimestampIndex: index)
            }
            #expect(error?.message == "A timestamp index requires an event log")
            let equivalent = raw.deletingLastPathComponent().appendingPathComponent("./events.ndjson")
            for alias in [raw, equivalent] {
                await expectRejectedLaunch(raw: raw, index: alias)
            }
            #expect(!FileManager.default.fileExists(atPath: raw.path))
            try Data().write(to: raw)
            try FileManager.default.linkItem(at: raw, to: index)
            await expectRejectedLaunch(raw: raw, index: index)
            #expect(try Data(contentsOf: raw).isEmpty)
        }
    }

    #if os(macOS) || os(Windows)
    @Test func caseEquivalentNewTargetsAreRejectedBeforeSpawn() async throws {
        try await withPair { raw, _ in
            #if os(macOS)
            let values = try raw.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            guard values.volumeSupportsCaseSensitiveNames == false else { return }
            #endif
            let alias = raw.deletingLastPathComponent().appendingPathComponent("EVENTS.NDJSON")
            await expectRejectedLaunch(raw: raw, index: alias)
            #expect(!FileManager.default.fileExists(atPath: raw.path))
        }
    }
    #endif

    #if !os(Windows)
    @Test func symlinkAliasesAreRejectedBeforeSpawnAndWriterDoesNotFollowLinks() async throws {
        try await withPair { raw, index in
            try Data().write(to: raw)
            try FileManager.default.createSymbolicLink(at: index, withDestinationURL: raw)
            await expectRejectedLaunch(raw: raw, index: index)
            #expect(throws: ACPEventLogWriter.Failure.self) {
                try ACPEventLogWriter(index).append(Data(prompt.utf8))
            }
            #expect(try Data(contentsOf: raw).isEmpty)
        }
    }

    @Test func physicalOffsetsBeyond32BitsAndOwnerOnlyFiles() throws {
        try withPair { raw, index in
            let offset = UInt64(UInt32.max) + 16
            try Data().write(to: raw)
            let file = try FileHandle(forWritingTo: raw)
            try file.seek(toOffset: offset - 1)
            try file.write(contentsOf: Data([0x0A]))
            try file.close()
            try ACPEventLogWriter(raw, timestampIndex: index).append(Data(prompt.utf8))
            #expect(try readIndex(index).first?.offset == offset)
            let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
    }
    #endif

    private func expectRejectedLaunch(raw: URL, index: URL) async {
        let error = await #expect(throws: ACPEventLogWriter.Failure.self) {
            _ = try await ACPAgent.launch(
                agent: "does-not-exist-339", handlers: .standard(permission: .approveAll),
                eventLog: raw, eventLogTimestampIndex: index)
        }
        #expect(error?.message == "The event log and timestamp index must target different files")
    }

    private func readIndex(_ url: URL) throws -> [ACPEventLogIndexRecord] {
        try Data(contentsOf: url).split(separator: 0x0A).map {
            try JSONDecoder().decode(ACPEventLogIndexRecord.self, from: Data($0))
        }
    }

    private func withPair(_ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("events.ndjson")
        try body(raw, raw.appendingPathExtension("timestamps.ndjson"))
    }

    private func withPair(_ body: (URL, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("events.ndjson")
        try await body(raw, raw.appendingPathExtension("timestamps.ndjson"))
    }
}

private final class CallbackTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date.distantFuture
    var date: Date { lock.withLock { value } }
    func enter() {
        lock.withLock { value = Date() }
        // Permit equal clock ticks at entry, but make a time captured after this callback fail.
        Thread.sleep(forTimeInterval: 0.01)
    }
}

/// State is accessed only under the writer's lock; fail once after a three-byte prefix.
private final class FailingWrites: @unchecked Sendable {
    private var call = 0
    private let failIndex: Bool
    init(failIndex: Bool) { self.failIndex = failIndex }

    func write(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) throws -> Int {
        call += 1
        let partialCall = failIndex ? 2 : 1
        if call == partialCall {
            return try ACPEventLogWriter.write(descriptor, UnsafeRawBufferPointer(rebasing: buffer.prefix(3)))
        }
        if call == partialCall + 1 { throw ACPEventLogWriter.Failure(message: "injected I/O failure") }
        return try ACPEventLogWriter.write(descriptor, buffer)
    }
}
#endif
