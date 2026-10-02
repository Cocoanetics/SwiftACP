@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A session saved under an earlier built-in default command is read as the current one,
/// stays in the built-in's scope, and is found by the earlier command too; a record with a
/// custom launcher keeps it. Ports acpx 0.19.4's `builtin-command-migration.ts` tests
/// (openclaw/acpx#838, `session-persistence.test.ts` and `cli.test.ts`).
struct BuiltInCommandMigrationTests {
    private static let previousClaude = "npx -y @agentclientprotocol/claude-agent-acp@^0.76.0"
    private static let currentClaude = AgentRegistry.builtIn["claude"]!
    private static let currentClaudeArgv = AgentRegistry.argv(for: "claude")!

    /// A record as an earlier acpx stored it, under `command` with `argv` — written as
    /// stored, past the serializer, which would already save it under the current command.
    private static func stored(
        id: String, command: String, argv: [String]?, cwd: String, name: String? = nil,
        closed: Bool = false, lastUsedAt: String? = nil
    ) throws -> WireJSON {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: id, acpSessionId: id, agentCommand: command, cwd: cwd, createdAt: now,
            lastUsedAt: lastUsedAt ?? now)
        record.name = name
        record.closed = closed
        if closed { record.closedAt = now }
        guard case .object(let members)? = WireJSON(parsing: try SessionRecordSerializer.data(for: record)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var kept = members.filter { $0.key != Array("agent_argv".utf16) }
        if let argv { kept.append(WireJSON.Member("agent_argv", .array(argv.map(WireJSON.text)))) }
        return WireJSON.object(kept).replacing("agent_command", with: .text(command))
    }

    /// `stored(...)`, saved in the store.
    private static func save(
        id: String, command: String, argv: [String]?, cwd: String, name: String? = nil,
        closed: Bool = false, lastUsedAt: String? = nil
    ) throws {
        let raw = try stored(
            id: id, command: command, argv: argv, cwd: cwd, name: name, closed: closed, lastUsedAt: lastUsedAt)
        try SessionStore.createSessionsDirectory()
        try Data((raw.stringified(indent: 2) + "\n").utf8).write(to: ACPXPaths.sessionRecordPath(id))
    }

    private static func strings(_ value: WireJSON?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        return items.compactMap(\.stringValue)
    }

    private static func workingDirectory() throws -> String {
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("acpx-migration-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        return cwd
    }

    /// A launch identity an earlier acpx saved, and the built-in it was a default of.
    private struct Saved {
        let command: String
        let argv: [String]?
        let name: String
    }

    // MARK: - parse

    @Test func parseMigratesRecordsSavedUnderEarlierBuiltInCommands() async throws {
        let cases = [
            Saved(
                command: Self.previousClaude, argv: ["npx", "-y", "@agentclientprotocol/claude-agent-acp@^0.76.0"],
                name: "claude"),
            Saved(command: "npx -y @agentclientprotocol/claude-agent-acp@^0.60.0", argv: nil, name: "claude"),
            Saved(command: "npm exec @agentclientprotocol/claude-agent-acp@^0.76.0", argv: nil, name: "claude"),
            Saved(command: Self.previousClaude, argv: Self.currentClaudeArgv, name: "claude"),
            Saved(command: "npx pi-acp@^0.0.31", argv: ["npx", "pi-acp@^0.0.31"], name: "pi")
        ]
        try await withIsolatedStore {
            for testCase in cases {
                let raw = try Self.stored(
                    id: "rec", command: testCase.command, argv: testCase.argv, cwd: "/tmp/built-in-identity-migration")
                let parsed = try #require(SessionRecordParser.parse(raw), "\(testCase.command)")
                let (command, argv) = (parsed["agentCommand"]?.stringValue, Self.strings(parsed["agentArgv"]))
                #expect(command == AgentRegistry.builtIn[testCase.name], "\(testCase.command)")
                #expect(argv == AgentRegistry.argv(for: testCase.name), "\(testCase.command)")
            }
        }
    }

    @Test func parseKeepsCustomLaunchersThatAreNotEarlierBuiltInDefaults() async throws {
        let cases: [(command: String, argv: [String])] = [
            (Self.previousClaude, ["/opt/claude-agent-acp/bin/claude-agent-acp", "--debug"]),
            ("npx -y @agentclientprotocol/claude-agent-acp@0.76.0",
             ["npx", "-y", "@agentclientprotocol/claude-agent-acp@0.76.0"]),
            ("custom-agent --acp", ["custom-agent", "--acp"])
        ]
        try await withIsolatedStore {
            for testCase in cases {
                let raw = try Self.stored(
                    id: "rec", command: testCase.command, argv: testCase.argv, cwd: "/tmp/built-in-identity-migration")
                let parsed = try #require(SessionRecordParser.parse(raw), "\(testCase.command)")
                #expect(parsed["agentCommand"]?.stringValue == testCase.command, "\(testCase.command)")
                #expect(Self.strings(parsed["agentArgv"]) == testCase.argv, "\(testCase.command)")
            }
        }
    }

    /// The model reads the migrated identity too, and the next write saves it under the
    /// current command.
    @Test func aMigratedRecordIsReadAndWrittenUnderTheCurrentCommand() async throws {
        try await withIsolatedStore {
            try Self.save(
                id: "saved-before-upgrade", command: Self.previousClaude,
                argv: ["npx", "-y", "@agentclientprotocol/claude-agent-acp@^0.76.0"], cwd: "/tmp/work")
            let record = try #require(SessionStore.loadRecord("saved-before-upgrade"))
            #expect(record.agentCommand == Self.currentClaude)
            #expect(record.agentArgv == Self.currentClaudeArgv)

            let written = try #require(WireJSON(parsing: SessionRecordSerializer.data(for: record)))
            #expect(written["agent_command"]?.stringValue == Self.currentClaude)
            #expect(Self.strings(written["agent_argv"]) == Self.currentClaudeArgv)
        }
    }

    // MARK: - scope

    @Test func agentScopedLookupFindsSessionsSavedUnderThePreviousClaudeCommand() async throws {
        try await withIsolatedStore {
            let cwd = "/tmp/workspace"
            try Self.save(
                id: "saved-before-upgrade", command: Self.previousClaude,
                argv: ["npx", "-y", "@agentclientprotocol/claude-agent-acp@^0.76.0"], cwd: cwd)
            try Self.save(
                id: "closed-before-upgrade", command: Self.previousClaude, argv: nil, cwd: cwd, name: "old",
                closed: true)

            for agentCommand in [Self.currentClaude, Self.previousClaude] {
                let found = SessionStore.findSession(agentCommand: agentCommand, cwd: cwd, name: nil)
                #expect(found?.acpxRecordId == "saved-before-upgrade", "\(agentCommand)")
                #expect(found?.agentCommand == Self.currentClaude, "\(agentCommand)")
                #expect(found?.agentArgv == Self.currentClaudeArgv, "\(agentCommand)")

                let walked = SessionStore.findSessionByDirectoryWalk(
                    agentCommand: agentCommand, cwd: cwd, name: nil, boundary: nil)
                #expect(walked?.acpxRecordId == "saved-before-upgrade", "\(agentCommand)")

                let listed = SessionStore.listSessions(forAgent: agentCommand).map(\.acpxRecordId).sorted()
                #expect(listed == ["closed-before-upgrade", "saved-before-upgrade"], "\(agentCommand)")
            }

            // Prune takes its candidates from the agent's scope: the CLI's from
            // `listSessions(forAgent:)`, the daemon's from `sessions(matchingAgent:)`.
            let closed = SessionStore.listSessions(forAgent: Self.currentClaude).filter { $0.closed == true }
            #expect(closed.map(\.acpxRecordId) == ["closed-before-upgrade"])
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let pruned = await daemon.pruneSessions(agentCommand: Self.currentClaude, dryRun: true)
            #expect(pruned.pruned == ["closed-before-upgrade"])
            #expect(await daemon.listSessions(agentCommand: Self.previousClaude).map(\.id).sorted()
                == ["closed-before-upgrade", "saved-before-upgrade"])

            #expect(SessionStore.findSession(agentCommand: AgentRegistry.builtIn["codex"]!, cwd: cwd, name: nil) == nil)
        }
    }

    @Test func everyEarlierBuiltInDefaultStaysInItsAgentsScopeAfterMigration() async throws {
        let entries = BuiltInCommandMigration.legacyCommands.flatMap { entry in
            entry.commands.enumerated().map { (name: entry.name, command: $0.element, index: $0.offset) }
        }
        #expect(entries.count > 30)
        try await withIsolatedStore {
            for entry in entries {
                try Self.save(
                    id: "\(entry.name)-\(entry.index)", command: entry.command,
                    argv: AgentRegistry.splitCommandLine(entry.command), cwd: "/tmp/\(entry.name)/\(entry.index)")
            }
            for entry in entries {
                let current = try #require(AgentRegistry.builtIn[entry.name], "\(entry.name)")
                for query in [current, entry.command] {
                    let found = SessionStore.findSession(
                        agentCommand: query, cwd: "/tmp/\(entry.name)/\(entry.index)", name: nil)
                    #expect(found?.acpxRecordId == "\(entry.name)-\(entry.index)", "\(entry.command) via \(query)")
                    #expect(found?.agentCommand == current, "\(entry.command)")
                    #expect(found?.agentArgv == AgentRegistry.argv(for: entry.name), "\(entry.command)")
                }
            }
        }
    }

    @Test func exactCommandLookupStillFindsCustomLaunchersSavedUnderAnEarlierBuiltInCommand() async throws {
        try await withIsolatedStore {
            let cwd = "/tmp/workspace"
            let customArgv = ["/opt/claude-agent-acp/bin/claude-agent-acp", "--debug"]
            try Self.save(id: "custom-launcher", command: Self.previousClaude, argv: customArgv, cwd: cwd)

            let found = SessionStore.findSession(agentCommand: Self.previousClaude, cwd: cwd, name: nil)
            #expect(found?.acpxRecordId == "custom-launcher")
            #expect(found?.agentCommand == Self.previousClaude)
            #expect(found?.agentArgv == customArgv)
            #expect(SessionStore.findSession(agentCommand: Self.currentClaude, cwd: cwd, name: nil) == nil)

            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(await daemon.listSessions(agentCommand: Self.previousClaude).map(\.id) == ["custom-launcher"])
            #expect(await daemon.listSessions(agentCommand: "claude").isEmpty)
        }
    }

    @Test func agentScopedLookupPrefersTheMostRecentlyUsedOfMigratedAndCurrentRecords() async throws {
        try await withIsolatedStore {
            let cwd = "/tmp/workspace"
            try Self.save(
                id: "previous-scope", command: Self.previousClaude, argv: nil, cwd: cwd,
                lastUsedAt: "2026-01-02T00:00:00.000Z")
            try Self.save(
                id: "current-scope", command: Self.currentClaude, argv: nil, cwd: cwd,
                lastUsedAt: "2026-01-03T00:00:00.000Z")
            let found = SessionStore.findSession(agentCommand: Self.currentClaude, cwd: cwd, name: nil)
            #expect(found?.acpxRecordId == "current-scope")
        }
    }

    // MARK: - CLI

    /// acpx's `CLI finds claude sessions saved under the previous built-in command`.
    @Test func sessionsShowFindsAClaudeSessionSavedUnderThePreviousBuiltInCommand() async throws {
        try await withIsolatedStore {
            let cwd = try Self.workingDirectory()
            try Self.save(
                id: "saved-before-upgrade", command: Self.previousClaude,
                argv: ["npx", "-y", "@agentclientprotocol/claude-agent-acp@^0.76.0"], cwd: cwd)
            for agentArguments in [["claude"], ["--agent", Self.previousClaude]] {
                let arguments = ["--cwd", cwd, "--format", "json"] + agentArguments + ["sessions", "show"]
                let capture = Console.Capture()
                let code = Console.$capture.withValue(capture) { runCommandLine(arguments) }
                #expect(code == ExitCodes.success, "\(arguments): \(capture.err)")
                let shown = try #require(WireJSON(parsing: Data(capture.out.utf8)), "\(arguments)")
                #expect(shown["acpxRecordId"]?.stringValue == "saved-before-upgrade", "\(arguments)")
                #expect(shown["agentCommand"]?.stringValue == Self.currentClaude, "\(arguments)")
            }
        }
    }
}
