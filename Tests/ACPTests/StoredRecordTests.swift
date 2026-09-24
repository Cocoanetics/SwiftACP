@testable import ACPXCore
@testable import acpx
import Foundation
import Testing

/// In `--format json`, `sessions show` and `sessions list` print acpx's in-memory records:
/// the stored file as acpx's parser makes it. A file that parser rejects is no record
/// at all (#77). The records and the output expected for them are the parser fixture's,
/// which acpx 0.19.1 printed.
///
/// Serialized because the tests redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct StoredRecordTests {
    private struct Case: Decodable {
        let name: String
        let raw: String
        let parsed: String?
    }

    private static func fixtureCase(_ name: String) throws -> Case {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/acpx-record-parse.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixture))
        return try #require(cases.first { $0.name == name })
    }

    /// Stores `raw` as the record `rec-1`, its `/work` working directory moved to `cwd`.
    private static func store(_ raw: String, cwd: String) throws {
        try FileManager.default.createDirectory(at: ACPXPaths.sessionsDir, withIntermediateDirectories: true)
        try Data(raw.replacingOccurrences(of: #""/work""#, with: #""\#(cwd)""#).utf8)
            .write(to: ACPXPaths.sessionRecordPath("rec-1"))
    }

    private static func workingDirectory() throws -> String {
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("acpx-stored-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        return cwd
    }

    @Test func showAndListPrintAcpxsRecord() async throws {
        let full = try Self.fixtureCase("full record")
        try await withIsolatedStore {
            let cwd = try Self.workingDirectory()
            try Self.store(full.raw, cwd: cwd)
            let expected = try #require(full.parsed).replacingOccurrences(of: #""/work""#, with: #""\#(cwd)""#)
            for (arguments, output) in [
                (["--format", "json", "--cwd", cwd, "codex", "sessions", "show", "alpha"], expected + "\n"),
                (["--format", "json", "--cwd", cwd, "codex", "sessions", "list"], "[" + expected + "]\n")
            ] {
                let capture = Console.Capture()
                let code = Console.$capture.withValue(capture) { runCommandLine(arguments) }
                #expect(code == ExitCodes.success, "\(arguments)")
                #expect(capture.out == output, "\(arguments)")
            }
        }
    }

    /// Every fixture record: SwiftACP reads it exactly when acpx does — including one
    /// acpx reads leniently, whose unreadable fields it drops or defaults instead.
    @Test func aRecordIsReadExactlyWhenAcpxReadsIt() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/acpx-record-parse.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixture))
        try await withIsolatedStore {
            let cwd = try Self.workingDirectory()
            for testCase in cases where testCase.raw.contains(#""rec-1""#) {
                try Self.store(testCase.raw, cwd: cwd)
                #expect((SessionStore.loadRecord("rec-1") != nil) == (testCase.parsed != nil), "\(testCase.name)")
            }
        }
    }

    /// SwiftACP's own restrictions fail closed when they do not read — the fields
    /// themselves, or the whole `acpx` block they live in: no client capabilities
    /// rather than the defaults, and no MCP servers rather than the config file's. The
    /// record itself is still read, as acpx reads it.
    @Test func anUnreadableRestrictionFailsClosed() async throws {
        let unreadable = try Self.fixtureCase("acpx own field unreadable")
        try await withIsolatedStore {
            try Self.store(unreadable.raw, cwd: try Self.workingDirectory())
            let record = try #require(SessionStore.loadRecord("rec-1"))
            #expect(record.acpx?.clientCapabilities
                == .init(readTextFile: false, writeTextFile: false, terminal: false))
            #expect(record.acpx?.mcpServers?.isEmpty == true)
        }
        for name in ["acpx not an object", "acpx null"] {
            let whole = try Self.fixtureCase(name)
            try await withIsolatedStore {
                try Self.store(whole.raw, cwd: try Self.workingDirectory())
                let record = try #require(SessionStore.loadRecord("rec-1"), "\(name)")
                #expect(record.acpx?.clientCapabilities
                    == .init(readTextFile: false, writeTextFile: false, terminal: false), "\(name)")
                #expect(record.acpx?.mcpServers?.isEmpty == true, "\(name)")
            }
        }
        let absent = try Self.fixtureCase("acpx empty")
        try await withIsolatedStore {
            try Self.store(absent.raw, cwd: try Self.workingDirectory())
            let record = try #require(SessionStore.loadRecord("rec-1"))
            #expect(record.acpx?.clientCapabilities == nil)
            #expect(record.acpx?.mcpServers == nil)
        }
    }

    /// A `max_turns` beyond what the model's `Int` holds, which acpx accepts, does not
    /// cost the other session options: they still read.
    @Test func sessionOptionsSurviveAnOverflowingMaxTurns() async throws {
        let overflowing = try Self.fixtureCase("acpx max turns beyond Int")
        #expect(overflowing.parsed?.contains(#""max_turns":100000000000000000000"#) == true)
        try await withIsolatedStore {
            try Self.store(overflowing.raw, cwd: try Self.workingDirectory())
            let options = try #require(SessionStore.loadRecord("rec-1")?.acpx?.sessionOptions)
            #expect(options.model == "opus")
            #expect(options.allowedTools == ["read"])
            #expect(options.maxTurns == 9_007_199_254_740_992)
        }
    }

    /// A record prints as it was when it was read — the read that selected it — not as
    /// the file says by the time it is printed.
    @Test func aRecordPrintsAsItWasRead() async throws {
        let full = try Self.fixtureCase("full record")
        try await withIsolatedStore {
            let cwd = try Self.workingDirectory()
            try Self.store(full.raw, cwd: cwd)
            let record = try #require(SessionStore.loadRecord("rec-1"))
            try Self.store(full.raw.replacingOccurrences(of: #""alpha""#, with: #""beta""#), cwd: cwd)

            let expected = try #require(full.parsed).replacingOccurrences(of: #""/work""#, with: #""\#(cwd)""#)
            let capture = Console.Capture()
            Console.$capture.withValue(capture) {
                SessionsCommand.printSessionDetails(record, format: "json")
                SessionsCommand.printSessions([record], format: "json")
            }
            #expect(capture.out == expected + "\n[" + expected + "]\n")
        }
    }

    @Test func aFileAcpxRejectsIsNoRecord() async throws {
        let rejected = try Self.fixtureCase("pid zero")
        #expect(rejected.parsed == nil)
        try await withIsolatedStore {
            try Self.store(rejected.raw, cwd: try Self.workingDirectory())
            #expect(SessionStore.loadRecord("rec-1") == nil)
            #expect(SessionStore.listSessions().isEmpty)
        }
    }
}
