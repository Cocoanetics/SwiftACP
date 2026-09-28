@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import Testing

/// `sessions prune --include-history` removes every stream file acpx's `isSessionStreamFile`
/// names — the session's active log, its lock, and every segment, however many rotation kept —
/// counting the bytes `stat` gives for each, as acpx's prune does (#252).
@Suite(.serialized) struct PruneHistoryTests {
    private static let agent = "/opt/agents/prune-agent"

    /// Names that only look like the session `gone`'s: not its stream files.
    private static let lookalikes = [
        "gone.stream.1a.ndjson", "gone.stream..ndjson", "gone.stream.ndjson.bak", "gone.streams.ndjson",
        "gone.stream.\u{661}.ndjson", "gonex.stream.ndjson"
    ]

    /// The closed session `gone`, as `sessions prune` finds one.
    private static func writeClosedRecord() throws {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: "gone", acpSessionId: "gone", agentCommand: agent, cwd: "/tmp", createdAt: now,
            lastUsedAt: now)
        record.closed = true
        record.closedAt = now
        try SessionStore.writeRecord(record)
    }

    /// The path of `name` in the sessions directory.
    private static func file(_ name: String) -> String {
        ACPXPaths.sessionsDir.appendingPathComponent(name).path
    }

    /// The size `stat` gives for `name`: a link's target's.
    private static func size(_ name: String) -> Int {
        var status = stat()
        return stat(file(name), &status) == 0 ? Int(status.st_size) : 0
    }

    /// What of the session `gone`'s — and what looks like it — is left.
    private static func left() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: ACPXPaths.sessionsDir.path)
            .filter { $0.hasPrefix("gone") }.sorted()
    }

    /// Stream files of `gone`'s, each of its own size, and the lookalikes.
    private static func writeHistory(_ history: [String]) throws {
        for (index, name) in history.enumerated() {
            try String(repeating: "x", count: index + 1).write(toFile: file(name), atomically: false, encoding: .utf8)
        }
        for name in lookalikes { try "keep\n".write(toFile: file(name), atomically: false, encoding: .utf8) }
    }

    @Test func historyGoesWithEveryStreamFileOfTheSession() async throws {
        let outside = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try await withIsolatedStore {
            try Self.writeClosedRecord()
            // Its active log, its lock, and segments past the five rotation keeps.
            let history = [
                "gone.stream.ndjson", "gone.stream.lock", "gone.stream.1.ndjson", "gone.stream.7.ndjson",
                "gone.stream.12.ndjson"
            ]
            try Self.writeHistory(history)
            // A directory by a segment's name is counted but stays; a link goes, counted as its
            // target, which stays.
            try FileManager.default.createDirectory(
                atPath: Self.file("gone.stream.2.ndjson"), withIntermediateDirectories: false)
            let target = outside.appendingPathComponent("target").path
            try "the target\n".write(toFile: target, atomically: false, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                atPath: Self.file("gone.stream.3.ndjson"), withDestinationPath: target)
            let counted = ["gone.json"] + history + ["gone.stream.2.ndjson", "gone.stream.3.ndjson"]
            let expected = counted.map(Self.size).reduce(0, +)

            let run = CLIParityTests.run(
                ["--agent", Self.agent, "--format", "json", "sessions", "prune", "--include-history"])
            #expect(run.code == ExitCodes.success, "\(run.err)")
            let result = try #require(try JSONSerialization.jsonObject(with: Data(run.out.utf8)) as? [String: Any])
            #expect(result["bytesFreed"] as? Int == expected)
            #expect(try Self.left() == (Self.lookalikes + ["gone.stream.2.ndjson"]).sorted())
            #expect(FileManager.default.fileExists(atPath: target))
        }
    }

    /// Without `--include-history`, the record alone goes.
    @Test func withoutHistoryTheRecordAloneGoes() async throws {
        try await withIsolatedStore {
            try Self.writeClosedRecord()
            let history = ["gone.stream.ndjson", "gone.stream.lock", "gone.stream.9.ndjson"]
            try Self.writeHistory(history)
            let expected = Self.size("gone.json")

            let run = CLIParityTests.run(["--agent", Self.agent, "--format", "json", "sessions", "prune"])
            #expect(run.code == ExitCodes.success, "\(run.err)")
            let result = try #require(try JSONSerialization.jsonObject(with: Data(run.out.utf8)) as? [String: Any])
            #expect(result["bytesFreed"] as? Int == expected)
            #expect(try Self.left() == (Self.lookalikes + history).sorted())
        }
    }

    /// The daemon's `pruneSessions` removes the same files.
    @Test func theDaemonsPruneTakesTheSameHistory() async throws {
        try await withIsolatedStore {
            try Self.writeClosedRecord()
            let history = ["gone.stream.ndjson", "gone.stream.lock", "gone.stream.9.ndjson"]
            try Self.writeHistory(history)
            let expected = (["gone.json"] + history).map(Self.size).reduce(0, +)

            let result = await ACPXDaemonBackend(inheritAgentStderr: false).pruneSessions(includeHistory: true)
            #expect(result.pruned == ["gone"])
            #expect(result.bytesFreed == expected)
            #expect(try Self.left() == Self.lookalikes.sorted())
        }
    }
}
