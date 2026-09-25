@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// `sessions export` and `sessions import` carry a session as acpx carries it (#58): the
/// archive acpx writes of a record, the record acpx makes of that archive, and every
/// archive acpx refuses, in its words. The fixture is npm acpx 0.19.1's: the record
/// exported, its archive imported into another home, and each refused variant's message.
///
/// Serialized because the tests redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct SessionArchiveTests {
    struct Fixture: Decodable {
        struct Refusal: Decodable {
            let name: String
            let agent: String
            let archive: String
            let exitCode: Int32
            let error: String
        }

        /// The command of the `probe` agent the archive was exported for.
        let command: String
        let record: String
        let segments: [String: String]
        let archive: String
        let imported: String
        let importedHistory: String
        let olderCodexCommand: String
        let importedForCodex: String
        let refusals: [Refusal]
    }

    struct Run {
        let code: Int32
        let out: String
        let err: String
    }

    /// A session an export may find running: its record's text changed by `edit`, and its
    /// event log's lock — a directory for `""` — and how the export is refused, if it is.
    struct RunningCase {
        let label: String
        let edit: (String) -> String
        var lock: String?
        var refused: Run?
    }

    static let exportedAt = "2026-09-24T12:00:00.000Z"
    static let locked =
        "session is currently locked by a running queue owner; close it first with `acpx sessions close`\n"

    static func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/acpx-session-archive.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// The whole CLI, run on `arguments`, and what it printed.
    static func run(_ arguments: [String]) -> Run {
        let capture = Console.Capture()
        let code = Console.$capture.withValue(capture) { runCommandLine(arguments) }
        return Run(code: code, out: capture.out, err: capture.err)
    }

    /// A new directory, its path with symbolic links resolved.
    static func directory() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("acpx-archive-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func text(at path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }

    static func mode(of path: String) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? NSNumber).uint16Value
    }

    /// The fixture's archive, exported at ``exportedAt``, as the file `path`.
    static func writeArchive(_ fixture: Fixture, to path: String) throws {
        try write(fixture.archive.replacingOccurrences(of: "<exported_at>", with: exportedAt), to: path)
    }

    /// The `probe` agent the archive was exported for, in the global config.
    static func configureProbe(_ fixture: Fixture) throws {
        try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
        try write(#"{"agents": {"probe": {"command": "\#(fixture.command)"}}}"#, to: ACPXPaths.globalConfigPath.path)
    }

    /// The fixture's record and event log as the record `id`, its home at `home` and its
    /// text changed by `edit`.
    static func storeSource(
        _ fixture: Fixture, home: String, id: String = "rec-1", edit: (String) -> String = { $0 }
    ) throws {
        try FileManager.default.createDirectory(at: ACPXPaths.sessionsDir, withIntermediateDirectories: true)
        let record = edit(fixture.record.replacingOccurrences(of: "<home>", with: home))
            .replacingOccurrences(of: #""acpx_record_id": "rec-1""#, with: #""acpx_record_id": "\#(id)""#)
        try write(record, to: ACPXPaths.sessionRecordPath(id).path)
        for (segment, text) in fixture.segments {
            let url = Int(segment).map { ACPXPaths.sessionStreamSegmentPath(id, segment: $0) }
                ?? ACPXPaths.sessionStreamPath(id)
            try write(text, to: url.path)
        }
    }

    /// `record` open, its agent process `pid` — none when `nil`.
    static func opened(_ record: String, pid: Int32? = nil) -> String {
        record.replacingOccurrences(of: #""closed": true"#, with: #""closed": false"#)
            .replacingOccurrences(of: #""pid": 4242,"#, with: pid.map { #""pid": \#($0),"# } ?? "")
    }

    // MARK: - The archive and the record

    /// The archive of a record is acpx's to the byte: its fields, the record as acpx
    /// writes it with its directory relative to home, and every ACP message of its event
    /// log — oldest segment first, past a CRLF, a torn last line and lines that are no
    /// message.
    @Test func anExportIsTheArchiveAcpxWrites() async throws {
        let fixture = try Self.fixture()
        try await withIsolatedStore {
            try Self.storeSource(fixture, home: "/home/user")
            let record = try #require(SessionStore.loadRecord("rec-1"))
            let output = try Self.directory() + "/out.json"

            try SessionArchive.export(
                record, agentName: "probe", to: output, home: "/home/user", exportedAt: Self.exportedAt)

            let written = try Self.text(at: output)
            #expect(written == fixture.archive.replacingOccurrences(of: "<exported_at>", with: Self.exportedAt))
            #expect(try Self.mode(of: output) == 0o600)
        }
    }

    /// The archive imported is the record acpx makes of it: a new id, its directory under
    /// home, nothing of how its agent last ran, a fresh event log holding the history —
    /// all of it private — and where it came from.
    @Test func anImportIsTheRecordAcpxMakes() async throws {
        let fixture = try Self.fixture()
        try await withIsolatedStore {
            let archive = try Self.directory() + "/archive.json"
            try Self.writeArchive(fixture, to: archive)
            try FileManager.default.removeItem(at: ACPXPaths.baseDir)
            // A directory made as acpx makes the store's here, with the default mode.
            let made = try Self.directory() + "/made"
            try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: false)

            let imported = try SessionArchive.importArchive(
                at: archive, name: nil, cwd: nil, expectedAgentName: "probe",
                expectedAgentCommand: fixture.command, home: "/home/user")

            #expect(imported.cwd == "/home/user/proj/x")
            #expect(UUID(uuidString: imported.recordId) != nil && imported.recordId == imported.recordId.lowercased())
            let recordPath = ACPXPaths.sessionRecordPath(imported.recordId).path
            let historyPath = ACPXPaths.sessionStreamPath(imported.recordId).path
            #expect(try Self.text(at: recordPath) == fixture.imported
                .replacingOccurrences(of: "<home>/.acpx/sessions", with: ACPXPaths.sessionsDir.path)
                .replacingOccurrences(of: "<home>", with: "/home/user")
                .replacingOccurrences(of: "<id>", with: imported.recordId)
                .replacingOccurrences(of: "<exported_at>", with: Self.exportedAt))
            #expect(try Self.text(at: historyPath) == fixture.importedHistory)
            #expect(try Self.mode(of: recordPath) == 0o600)
            #expect(try Self.mode(of: historyPath) == 0o600)
            #expect(try Self.mode(of: ACPXPaths.sessionsDir.path) == 0o700)
            #expect(try Self.mode(of: ACPXPaths.baseDir.path) == Self.mode(of: made))
        }
    }

    /// An archive of an older release of a built-in agent's adapter imports for that
    /// agent, and its record then runs the command the agent runs now.
    @Test func anOlderBuiltInsArchiveTakesTheBuiltInsCommand() async throws {
        let fixture = try Self.fixture()
        let codex = try #require(AgentRegistry.builtIn["codex"])
        try await withIsolatedStore {
            let archive = try Self.directory() + "/archive.json"
            try Self.write(
                fixture.archive.replacingOccurrences(of: "<exported_at>", with: Self.exportedAt)
                    .replacingOccurrences(of: #""\#(fixture.command)""#, with: #""\#(fixture.olderCodexCommand)""#)
                    .replacingOccurrences(of: #""agent_name": "probe","#, with: ""),
                to: archive)

            let imported = try SessionArchive.importArchive(
                at: archive, name: nil, cwd: nil, expectedAgentName: "codex", expectedAgentCommand: codex,
                home: "/home/user")

            #expect(try Self.text(at: ACPXPaths.sessionRecordPath(imported.recordId).path) == fixture.importedForCodex
                .replacingOccurrences(of: "<home>/.acpx/sessions", with: ACPXPaths.sessionsDir.path)
                .replacingOccurrences(of: "<home>", with: "/home/user")
                .replacingOccurrences(of: "<id>", with: imported.recordId)
                .replacingOccurrences(of: "<exported_at>", with: Self.exportedAt))
            #expect(SessionStore.loadRecord(imported.recordId)?.agentCommand == codex)
        }
    }

    /// SwiftACP's own fields, which acpx does not know: a session's restrictions go with
    /// it and come back — one made under `--no-fs` must not get the filesystem back — but
    /// its MCP servers, whose commands and credentials are this machine's, do neither.
    @Test func restrictionsTravelButMCPServersDoNot() async throws {
        let fixture = try Self.fixture()
        try await withIsolatedStore {
            try Self.storeSource(fixture, home: "/home/user")
            var record = try #require(SessionStore.loadRecord("rec-1"))
            let restricted = SessionAcpxState.PersistedCapabilities(
                readTextFile: true, writeTextFile: false, terminal: false)
            record.acpx?.clientCapabilities = restricted
            record.acpx?.mcpServers = [try JSONDecoder().decode(McpServerConfig.self, from: Data(
                #"{"name": "secret", "command": "run-me", "env": [{"name": "TOKEN", "value": "t0ken"}]}"#.utf8))]
            let archive = try Self.directory() + "/archive.json"

            try SessionArchive.export(
                record, agentName: "probe", to: archive, home: "/home/user", exportedAt: Self.exportedAt)

            let exported = try Self.text(at: archive)
            #expect(exported.contains(#""client_capabilities": {"#))
            #expect(!exported.contains("mcp_servers") && !exported.contains("t0ken"))

            // A hand-made archive that brings MCP servers anyway is imported without them.
            try Self.write(
                exported.replacingOccurrences(
                    of: #""client_capabilities": {"#,
                    with: #""mcp_servers": [{"name": "s", "command": "run-me"}], "client_capabilities": {"#),
                to: archive)
            try FileManager.default.removeItem(at: ACPXPaths.sessionRecordPath("rec-1"))
            let imported = try SessionArchive.importArchive(
                at: archive, name: nil, cwd: nil, expectedAgentName: "probe", expectedAgentCommand: fixture.command,
                home: "/home/user")

            let back = try #require(SessionStore.loadRecord(imported.recordId))
            #expect(back.acpx?.clientCapabilities == restricted)
            #expect(back.acpx?.mcpServers == nil)
        }
    }

    /// An archive names the agent a session ran, never how to launch one: an argv it
    /// carries beside the expected command is not what the imported session launches.
    /// The local agent's argv is — or, when the agent has none, its command.
    @Test func anArchiveCannotNameTheProgramToLaunch() async throws {
        let fixture = try Self.fixture()
        let payload: [String] = ["/bin/sh", "-c", "echo pwned"]
        try await withIsolatedStore {
            let parsed = try WireJSON.parse(
                fixture.archive.replacingOccurrences(of: "<exported_at>", with: Self.exportedAt))
            let session = try #require(parsed["session"])
            let state = try #require(session["state"])
            let crafted = parsed.replacing("session", with: session.replacing(
                "state", with: state.replacing("agent_argv", with: .array(payload.map(WireJSON.text)))))
            let archive = try Self.directory() + "/archive.json"
            try Self.write(crafted.stringified(indent: 2), to: archive)

            let plain = try SessionArchive.importArchive(
                at: archive, name: nil, cwd: nil, expectedAgentName: "probe", expectedAgentCommand: fixture.command,
                home: "/home/user")
            let plainArgv = SessionStore.loadRecord(plain.recordId)?.agentArgv
            try FileManager.default.removeItem(at: ACPXPaths.sessionRecordPath(plain.recordId))
            let launched = try SessionArchive.importArchive(
                at: archive, name: nil, cwd: nil, expectedAgentName: "probe", expectedAgentCommand: fixture.command,
                expectedAgentArgv: ["probe-agent", "--acp"], home: "/home/user")

            #expect(plainArgv != payload)
            #expect(plainArgv == nil || plainArgv?.first == "npx")
            #expect(SessionStore.loadRecord(launched.recordId)?.agentArgv == ["probe-agent", "--acp"])
        }
    }

    /// The environment a session's agent starts with is this machine's: an export leaves
    /// it out — it may hold credentials — and an import brings none, since it decides what
    /// the agent runs too. The session's other options travel.
    @Test func anArchiveCarriesNoEnvironment() async throws {
        let fixture = try Self.fixture()
        try await withIsolatedStore {
            try Self.storeSource(fixture, home: "/home/user")
            var record = try #require(SessionStore.loadRecord("rec-1"))
            var options = SessionAcpxState.SessionOptions()
            options.model = "gpt"
            options.env = ["API_TOKEN": "t0ken"]
            record.acpx?.sessionOptions = options
            let archive = try Self.directory() + "/archive.json"

            try SessionArchive.export(
                record, agentName: "probe", to: archive, home: "/home/user", exportedAt: Self.exportedAt)
            let exported = try Self.text(at: archive)
            try Self.write(
                exported.replacingOccurrences(
                    of: #""session_options": {"#,
                    with: #""session_options": {"env": {"NODE_OPTIONS": "--require /tmp/x.js"}, "#),
                to: archive)
            try FileManager.default.removeItem(at: ACPXPaths.sessionRecordPath("rec-1"))
            let imported = try SessionArchive.importArchive(
                at: archive, name: nil, cwd: nil, expectedAgentName: "probe", expectedAgentCommand: fixture.command,
                home: "/home/user")

            #expect(exported.contains(#""session_options": {"#) && !exported.contains("t0ken"))
            let back = try #require(SessionStore.loadRecord(imported.recordId))
            #expect(back.acpx?.sessionOptions?.model == "gpt")
            #expect(back.acpx?.sessionOptions?.env == nil)
        }
    }

    // MARK: - Refusals

    /// Every archive acpx refuses is refused with acpx's message and exit code — bad
    /// JSON, another format version, the first field zod finds wrong, a state that is no
    /// record, another agent's — and leaves no session behind.
    @Test func refusesWhatAcpxRefusesInItsWords() async throws {
        let fixture = try Self.fixture()
        #expect(fixture.refusals.count > 40)
        for refusal in fixture.refusals {
            try await withIsolatedStore {
                try Self.configureProbe(fixture)
                let cwd = try Self.directory()
                try Self.write(
                    refusal.archive.replacingOccurrences(of: "<exported_at>", with: Self.exportedAt),
                    to: cwd + "/archive.json")

                let run = Self.run(["--cwd", cwd, refusal.agent, "sessions", "import", cwd + "/archive.json"])

                #expect(run.code == refusal.exitCode, "\(refusal.name)")
                #expect(run.err == refusal.error + "\n", "\(refusal.name)")
                #expect(run.out.isEmpty, "\(refusal.name)")
                #expect(SessionStore.listSessions().isEmpty, "\(refusal.name)")
            }
        }
    }

    /// An archive imported once is refused again as acpx refuses it: its scope is
    /// taken, and under another name its agent's session is.
    @Test func aSecondImportIsRefused() async throws {
        let fixture = try Self.fixture()
        try await withIsolatedStore {
            try Self.configureProbe(fixture)
            let cwd = try Self.directory()
            try Self.writeArchive(fixture, to: cwd + "/archive.json")
            let arguments = ["--cwd", cwd, "probe", "sessions", "import", cwd + "/archive.json", "--cwd", cwd]
            let first = Self.run(arguments)
            let id = try #require(SessionStore.listSessions().first?.acpxRecordId)
            #expect(first.out == "imported session \(id) at \(cwd)\n")

            let again = Self.run(arguments)
            let renamed = Self.run(arguments + ["--name", "other"])
            let json = Self.run(["--format", "json"] + arguments)

            let scopeTaken = "A session already exists for the import destination scope; pass --name or --cwd to "
                + "import a separate copy"
            #expect(again.code == ExitCodes.usage)
            #expect(again.err == scopeTaken + "\n")
            #expect(renamed.code == ExitCodes.usage)
            #expect(renamed.err == "A local session already uses this provider session id; prune or remove the "
                + "existing record before importing this archive\n")
            #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32602,"message":""#
                + scopeTaken + #"","data":{"acpxCode":"USAGE","detailCode":"session-scope-exists","origin":"cli","#
                + #""sessionId":"unknown"}}}"# + "\n")
            #expect(SessionStore.listSessions().map(\.acpxRecordId) == [id])
            let logs = try FileManager.default.contentsOfDirectory(atPath: ACPXPaths.sessionsDir.path)
                .filter { $0.hasSuffix(".ndjson") }
            #expect(logs == ["\(id).stream.ndjson"])
        }
    }

    /// An archive that cannot be read fails as Node's read fails: a runtime error.
    @Test func anUnreadableArchiveFailsAsNodeReports() async throws {
        let fixture = try Self.fixture()
        try await withIsolatedStore {
            try Self.configureProbe(fixture)
            let cwd = try Self.directory()

            let missing = Self.run(["--cwd", cwd, "probe", "sessions", "import", cwd + "/none.json"])
            let directory = Self.run(["--cwd", cwd, "probe", "sessions", "import", cwd])

            #expect(missing.code == ExitCodes.error)
            #expect(missing.err == "ENOENT: no such file or directory, open '\(cwd)/none.json'\n")
            #expect(directory.code == ExitCodes.error)
            #expect(directory.err == "EISDIR: illegal operation on a directory, read\n")
        }
    }

    // MARK: - Home

    /// A session's directory travels relative to home when it is inside it — `..x` is
    /// not, to acpx — and comes back under the importing home, joined as `path.join`
    /// joins, a trailing slash kept.
    @Test func aDirectoryInsideHomeTravelsRelativeToIt() {
        #expect(SessionArchive.relativeToHome("/home/user/proj/x", home: "/home/user") == "proj/x")
        #expect(SessionArchive.relativeToHome("/home/user", home: "/home/user/") == ".")
        #expect(SessionArchive.relativeToHome("/home/username", home: "/home/user") == "/home/username")
        #expect(SessionArchive.relativeToHome("/home/user/..x/y", home: "/home/user") == "/home/user/..x/y")
        #expect(SessionArchive.relativeToHome("/", home: "/home/user") == "/")

        #expect(NodePath.join("/home/user", "proj/x/") == "/home/user/proj/x/")
        #expect(NodePath.join("/home/user", ".") == "/home/user")
        #expect(NodePath.join("/home/user", "") == "/home/user")
        #expect(NodePath.join("/home/user", "../other") == "/home/other")
    }

    /// acpx's home is Node's `os.homedir()`: `HOME` when it is set — which Foundation's
    /// home ignores — else the user's own.
    @Test func homeIsWhereHOMESays() {
        #expect(ACPXPaths.home(in: ["HOME": "/tmp/elsewhere/"]).path == "/tmp/elsewhere")
        #expect(ACPXPaths.home(in: [:]) == FileManager.default.homeDirectoryForCurrentUser)
    }
}
