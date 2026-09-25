@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

// `sessions export` as acpx runs it: the session it finds, one still running, where the
// archive goes, and what each format prints. Split from `SessionArchiveTests.swift` to
// keep that file inside the 500-line limit.
extension SessionArchiveTests {
    /// The session exported is the one acpx finds: by agent, directory and name —
    /// trimmed, and the directory against the global one — an open one before a closed
    /// one; with none, "session not found".
    @Test func anExportFindsTheSessionAcpxFinds() async throws {
        let fixture = try Self.fixture()
        try await withIsolatedStore {
            try Self.configureProbe(fixture)
            let home = try Self.directory()
            try Self.storeSource(fixture, home: home)
            try Self.storeSource(fixture, home: home, id: "rec-2") {
                Self.opened($0).replacingOccurrences(of: #""sess-1""#, with: #""sess-2""#)
            }
            let output = home + "/out.json"

            let found = Self.run([
                "--cwd", home, "probe", "sessions", "export", "  alpha  ", "--output", " \(output) ", "--cwd", "proj/x"
            ])
            let missing = Self.run(
                ["--cwd", home + "/proj/x", "probe", "sessions", "export", "beta", "--output", output])

            #expect(found.out == "exported session to \(output)\n")
            let archive = try #require(WireJSON(parsing: Data(contentsOf: URL(fileURLWithPath: output))))
            #expect(archive["session"]?["record_id"] == .text("rec-2"))
            #expect(missing.code == ExitCodes.usage)
            #expect(missing.err == "session not found\n")
        }
    }

    /// A session whose agent still runs is not exported — its process alive, or the
    /// queue owner holding its event log's lock alive. A closed session, a process gone
    /// or one not ours to signal, and a lock naming no live process do not hold it.
    @Test func aRunningSessionIsNotExported() async throws {
        let fixture = try Self.fixture()
        let live = getppid()
        let lockedOut = Run(code: ExitCodes.usage, out: "", err: Self.locked)
        let cases = [
            RunningCase(label: "its agent running", edit: { Self.opened($0, pid: live) }, refused: lockedOut),
            RunningCase(
                label: "closed, its agent running", edit: { $0.replacingOccurrences(of: "4242,", with: "\(live),") }),
            RunningCase(label: "its agent not ours to signal", edit: { Self.opened($0, pid: 1) }),
            RunningCase(label: "its agent this very process", edit: { Self.opened($0, pid: getpid()) }),
            RunningCase(label: "its agent gone", edit: { Self.opened($0, pid: 999_999) }),
            RunningCase(
                label: "its queue owner running", edit: { Self.opened($0) }, lock: #"{"pid": \#(live)}"#,
                refused: lockedOut),
            RunningCase(label: "closed, its queue owner running", edit: { $0 }, lock: #"{"pid": \#(live)}"#),
            RunningCase(label: "its queue owner gone", edit: { Self.opened($0) }, lock: #"{"pid": 999999}"#),
            RunningCase(label: "a lock naming no process", edit: { Self.opened($0) }, lock: #"{"pid": "\#(live)"}"#),
            RunningCase(label: "a lock that is no JSON", edit: { Self.opened($0) }, lock: "not json"),
            RunningCase(
                label: "a lock that is a directory", edit: { Self.opened($0) }, lock: "",
                refused: Run(code: ExitCodes.error, out: "", err: "EISDIR: illegal operation on a directory, read\n"))
        ]
        for testCase in cases {
            try await withIsolatedStore {
                try Self.configureProbe(fixture)
                let home = try Self.directory()
                try Self.storeSource(fixture, home: home, edit: testCase.edit)
                let lock = ACPXPaths.sessionStreamLockPath("rec-1")
                if testCase.lock == "" {
                    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
                } else if let text = testCase.lock {
                    try Self.write(text, to: lock.path)
                }
                let output = home + "/out.json"

                let run = Self.run(
                    ["--cwd", home + "/proj/x", "probe", "sessions", "export", "alpha", "--output", output])

                let exported = Run(code: ExitCodes.success, out: "exported session to \(output)\n", err: "")
                let expected = testCase.refused ?? exported
                #expect(run.code == expected.code, "\(testCase.label)")
                #expect(run.out == expected.out, "\(testCase.label)")
                #expect(run.err == expected.err, "\(testCase.label)")
                let written = FileManager.default.fileExists(atPath: output)
                #expect(written == (testCase.refused == nil), "\(testCase.label)")
            }
        }
    }

    /// The archive goes where acpx puts it: through a symbolic link — a relative one from
    /// the link's directory, a dangling one to the file it names — into directories made
    /// for it. A directory, and links without end, are refused.
    @Test func theArchiveGoesWhereAcpxPutsIt() async throws {
        let fixture = try Self.fixture()
        try await withIsolatedStore {
            try Self.storeSource(fixture, home: "/home/user")
            let record = try #require(SessionStore.loadRecord("rec-1"))
            let root = try Self.directory()
            let files = FileManager.default
            func export(to path: String) throws {
                try SessionArchive.export(
                    record, agentName: nil, to: path, home: "/home/user", exportedAt: Self.exportedAt)
            }
            try files.createDirectory(atPath: root + "/d", withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: root + "/d/link.json", withDestinationPath: "../dangling.json")
            try files.createSymbolicLink(atPath: root + "/a.json", withDestinationPath: root + "/b.json")
            try files.createSymbolicLink(atPath: root + "/b.json", withDestinationPath: root + "/a.json")

            try export(to: root + "/d/link.json")
            try export(to: root + "/new/deeper/out.json")

            #expect(files.fileExists(atPath: root + "/dangling.json"))
            #expect(try files.destinationOfSymbolicLink(atPath: root + "/d/link.json") == "../dangling.json")
            #expect(files.fileExists(atPath: root + "/new/deeper/out.json"))
            #expect(throws: SessionArchive.Failure(message: "Session export output must be a regular file")) {
                try export(to: root + "/d")
            }
            #expect(throws: SessionArchive.Failure(message: "Too many symbolic links in session export output")) {
                try export(to: root + "/a.json")
            }
        }
    }

    /// What each format prints for an export and an import: acpx's line, its JSON
    /// result, or only the path or the id.
    @Test func eachFormatPrintsWhatAcpxPrints() async throws {
        let fixture = try Self.fixture()
        for format in ["text", "json", "quiet"] {
            try await withIsolatedStore {
                try Self.configureProbe(fixture)
                let home = try Self.directory()
                try Self.storeSource(fixture, home: home)
                let output = home + "/out.json"
                let destination = home + "/copy"

                let exported = Self.run([
                    "--format", format, "--cwd", home + "/proj/x", "probe", "sessions", "export", "alpha",
                    "--output", output
                ])
                try FileManager.default.removeItem(at: ACPXPaths.sessionRecordPath("rec-1"))
                let imported = Self.run(
                    ["--format", format, "--cwd", home, "probe", "sessions", "import", output, "--cwd", "copy"])

                let id = try #require(SessionStore.listSessions().first?.acpxRecordId)
                let expected: (exported: String, imported: String) = switch format {
                case "json": (
                    #"{"action":"session_exported","output":"\#(output)"}"#,
                    #"{"action":"session_imported","record_id":"\#(id)","cwd":"\#(destination)"}"#)
                case "quiet": (output, id)
                default: ("exported session to \(output)", "imported session \(id) at \(destination)")
                }
                #expect(exported.out == expected.exported + "\n", "\(format)")
                #expect(imported.out == expected.imported + "\n", "\(format)")
            }
        }
    }
}
