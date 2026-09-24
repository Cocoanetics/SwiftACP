@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// A config agent with an `argv` — or a `command` with `args` — is launched with
/// exactly that argv, as acpx launches it, and a session records it as `agent_argv`
/// so every relaunch is the same (#74). A plain command line is split as acpx's
/// `splitCommandLine` splits it.
///
/// Serialized because the tests redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct AgentArgvTests {
    /// Arguments `JSON.stringify` would quote with escapes: re-split from the command
    /// acpx shows for them, they would arrive changed.
    private static let awkward = ["a b", #"say "hi""#, #"back\slash"#, "tab\there"]

    /// Each command line, what acpx 0.19.1's `splitCommandLine` made of it (the words
    /// after the executable), as a wrapper agent it launched logged them.
    @Test func splitsAsAcpxSplits() throws {
        let cases: [(String, [String])] = [
            (#"x "b c" 'd e'"#, ["b c", "d e"]),
            (#"x a\ b"#, ["a b"]),
            (#"x "say \"hi\"""#, [#"say "hi""#]),
            (#"x 'x\y'"#, [#"x\y"#]),
            (#"x tail\"#, [#"tail\"#]),
            ("x", []),
            (#"x """#, [""]),
            ("x a\tb", ["a", "b"]),
            ("x a\u{3000}b", ["a", "b"]),
            ("x a\u{85}b", ["a\u{85}b"]),
            (#"x "a"b'c'"#, ["abc"]),
            (#"x \"quoted\""#, [#""quoted""#])
        ]
        for (line, words) in cases {
            #expect(Array(try AgentRegistry.commandLineParts(line).dropFirst()) == words, "\(line)")
        }
        #expect(throws: AgentRegistry.CommandLineError(message: "Invalid --agent command: unterminated quote")) {
            try AgentRegistry.commandLineParts(#"x "open"#)
        }
        #expect(throws: AgentRegistry.CommandLineError(message: "Invalid --agent command: empty command")) {
            try AgentRegistry.commandLineParts(#""" x"#)
        }
    }

    private static func loggedArgv(_ log: URL) throws -> [[String]] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }

    /// The config for two agents that log their arguments: one with `argv`, one with a
    /// `command` and `args`.
    private static func writeConfig(argvLog: URL, argsLog: URL) throws {
        let mock = try #require(mockArgv())
        let agents: JSONValue = .object([
            "vec": .object(["argv": .array(
                (["/usr/bin/env", "MOCK_ARGV_LOG=\(argvLog.path)"] + mock + awkward).map(JSONValue.string))]),
            "old": .object([
                "command": .string("/usr/bin/env"),
                "args": .array((["MOCK_ARGV_LOG=\(argsLog.path)"] + mock + awkward).map(JSONValue.string))
            ])
        ])
        try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(JSONValue.object(["agents": agents])).write(to: ACPXPaths.globalConfigPath)
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aConfigAgentsArgvIsLaunchedAsGiven() async throws {
        try await withIsolatedStore {
            let argvLog = ACPXPaths.baseDir.appendingPathComponent("argv.log")
            let argsLog = ACPXPaths.baseDir.appendingPathComponent("args.log")
            try Self.writeConfig(argvLog: argvLog, argsLog: argsLog)
            let config = try ConfigLoader.load(cwd: NSTemporaryDirectory())
            for name in ["vec", "old"] {
                let launch = config.agentLaunch(for: name)
                let agent = try await ACPAgent.launch(
                    agent: launch.command, argv: launch.argv, cwd: NSTemporaryDirectory(), permission: .approveAll)
                await agent.close()
            }
            #expect(try Self.loggedArgv(argvLog) == [Self.awkward])
            #expect(try Self.loggedArgv(argsLog) == [Self.awkward])
        }
    }

    /// A session keeps the argv it was made with, and a restarted daemon launches it
    /// with that again.
    @Test(.enabled(if: mockPythonAvailable))
    func aSessionIsRelaunchedWithItsRecordedArgv() async throws {
        try await withIsolatedStore {
            let argvLog = ACPXPaths.baseDir.appendingPathComponent("argv.log")
            try Self.writeConfig(argvLog: argvLog, argsLog: ACPXPaths.baseDir.appendingPathComponent("args.log"))
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: "vec", cwd: NSTemporaryDirectory())
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.agentArgv?.suffix(Self.awkward.count) == Self.awkward[...])

            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "hi")
            #expect(try Self.loggedArgv(argvLog) == [Self.awkward, Self.awkward])
        }
    }

    /// `agent_argv` is written and read back; a malformed one reads as none, as acpx's
    /// `parseOptionalAgentArgv` has it.
    @Test func recordsKeepTheirArgv() async throws {
        try await withIsolatedStore {
            var record = SessionRecord(
                acpxRecordId: "r", acpSessionId: "s", agentCommand: "x", cwd: "/", createdAt: "t", lastUsedAt: "t")
            record.agentArgv = ["x", "a b"]
            try SessionStore.writeRecord(record)
            let written = try String(contentsOf: ACPXPaths.sessionRecordPath("r"), encoding: .utf8)
            #expect(written.contains(#""agent_argv" : ["#))
            #expect(SessionStore.loadRecord("r")?.agentArgv == ["x", "a b"])

            for stored in ["[]", #"[""]"#, "[1]"] {
                let json = #"{"schema":"acpx.session.v1","acpx_record_id":"r","acp_session_id":"s","#
                    + #""agent_command":"x","agent_argv":\#(stored),"cwd":"/","created_at":"t","last_used_at":"t"}"#
                try Data(json.utf8).write(to: ACPXPaths.sessionRecordPath("r"))
                let loaded = try #require(SessionStore.loadRecord("r"), "\(stored)")
                #expect(loaded.agentArgv == nil, "\(stored)")
            }
        }
    }
}
