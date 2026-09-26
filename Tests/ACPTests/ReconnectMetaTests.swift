@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
@testable import SwiftACP
import SwiftMCP
import Testing

/// The `_meta` on each request that gets a session back for a turn or a control:
/// `session/load` and `session/resume` carry the session's options as `session/new` does,
/// a prompt's own over the record's — acpx 0.19.3 starts its client with
/// `mergeSessionOptions(options.sessionOptions, sessionOptionsFromRecord(record))` (#778).
/// Each expectation is what acpx's build with 0.19.3's code sent on `model-agent.py`.
extension DaemonToolsTests {
    /// The options the sessions here are created with.
    private static var recordOptions: SessionAcpxState.SessionOptions {
        var options = SessionAcpxState.SessionOptions()
        options.allowedTools = ["Bash"]
        options.maxTurns = 5
        return options
    }

    /// A session on the model fixture created with ``recordOptions``, which it takes back
    /// with `session/load` when `load`, and the log of what the fixture was sent.
    private func metaSession(load: Bool) async throws -> (id: String, log: URL) {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py")
        try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
        let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
        let record = try await SessionEngine.createSession(
            agentCommand: "/usr/bin/env MODEL_AGENT_LOG='\(log.path)' " + (load ? "MODEL_AGENT_LOAD=1 " : "")
                + "'\(python)' '\(fixture.path)'",
            cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll, authCredentials: [:],
            authPolicy: "skip", sessionOptions: Self.recordOptions)
        return (record.acpxRecordId, log)
    }

    private static func lines(_ log: URL) -> [Substring] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
    }

    /// Each request past the first `skip` lines of `log` that got a session, with its `_meta`
    /// as JSON text, keys sorted.
    private static func connects(_ log: URL, after skip: Int) -> [String] {
        lines(log).dropFirst(skip).compactMap { line in
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = message["method"] as? String,
                  ["session/new", "session/load", "session/resume"].contains(method)
            else { return nil }
            let params = message["params"] as? [String: Any]
            guard let meta = params?["_meta"],
                  let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            else { return "\(method) -" }
            return "\(method) \(String(decoding: data, as: UTF8.self))"
        }
    }

    /// With no options of its own, a turn gets the session back with the record's.
    @Test(.enabled(if: mockPythonAvailable))
    func aLoadCarriesTheSessionsOptions() async throws {
        try await withIsolatedStore {
            let (id, log) = try await metaSession(load: true)
            let before = Self.lines(log).count
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await backend.runPrompt(sessionId: id, text: "hi")
            await backend.releaseAll()
            #expect(Self.connects(log, after: before) == [
                #"session/load {"claudeCode":{"options":{"allowedTools":["Bash"],"maxTurns":5}}}"#
            ])
        }
    }

    /// A turn's own options go over the record's, option by option.
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnsOptionsGoOverTheRecordsOnTheLoad() async throws {
        try await withIsolatedStore {
            let (id, log) = try await metaSession(load: true)
            let before = Self.lines(log).count
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await backend.runPrompt(
                sessionId: id, text: "hi",
                sessionOptions: PromptSessionOptions(allowedTools: ["Read"], appendSystemPrompt: "Also this"))
            await backend.releaseAll()
            #expect(Self.connects(log, after: before) == [
                #"session/load {"claudeCode":{"options":{"allowedTools":["Read"],"maxTurns":5}},"#
                    + #""systemPrompt":{"append":"Also this"}}"#
            ])
        }
    }

    /// A session started anew in place of one the agent cannot take back gets the same:
    /// the turn's model and tools over the record's, where only its model went before.
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnsOptionsGoOverTheRecordsOnAFreshSession() async throws {
        try await withIsolatedStore {
            let (id, log) = try await metaSession(load: false)
            let before = Self.lines(log).count
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await backend.runPrompt(
                sessionId: id, text: "hi", sessionOptions: PromptSessionOptions(model: "m2", allowedTools: ["Read"]))
            await backend.releaseAll()
            #expect(Self.connects(log, after: before) == [
                #"session/new {"claudeCode":{"options":{"allowedTools":["Read"],"maxTurns":5,"model":"m2"}}}"#
            ])
        }
    }

    /// A control gets the session back with the record's options: it has none of its own.
    @Test(.enabled(if: mockPythonAvailable))
    func aControlGetsTheSessionBackWithTheRecordsOptions() async throws {
        try await withIsolatedStore {
            let (id, log) = try await metaSession(load: true)
            let before = Self.lines(log).count
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await backend.setMode(sessionId: id, modeId: "plan")
            await backend.releaseAll()
            #expect(Self.connects(log, after: before) == [
                #"session/load {"claudeCode":{"options":{"allowedTools":["Bash"],"maxTurns":5}}}"#
            ])
        }
    }

    /// `acpx --approve-all --format quiet <args>`, with `daemon` the one running, if any: its exit code.
    private static func acpx(_ args: [String], daemon: MCPServerConfig? = nil) async -> Int32 {
        await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: DaemonClient.$standIn.withValue(daemon) {
                    Console.$capture.withValue(Console.Capture()) {
                        runCommandLine(["--approve-all", "--format", "quiet"] + args)
                    }
                })
            }.start()
        }
    }

    /// A prompt's flags reach the turn: the CLI sends them with the prompt, and the
    /// session created with its own is taken back with the prompt's over them.
    @Test(.enabled(if: mockPythonAvailable))
    func aPromptsFlagsReachTheLoad() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py")
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("requests.ndjson")
        let agent = "/usr/bin/env MODEL_AGENT_LOG='\(log.path)' MODEL_AGENT_LOAD=1 '\(python)' '\(fixture.path)'"
        let scope = ["--agent", agent, "--cwd", directory.path]
        try await withIsolatedStore {
            #expect(await Self.acpx(scope + ["--max-turns", "5", "--allowed-tools", "Bash", "sessions", "new"]) == 0)
            let before = Self.lines(log).count
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let code = await Self.acpx(
                scope + ["--allowed-tools", "Read", "--append-system-prompt", "Also this", "hi"],
                daemon: .stdioHandles(server: ACPXDaemon(backend: backend)))
            await backend.releaseAll()
            #expect(code == 0)
            #expect(Self.connects(log, after: before) == [
                #"session/load {"claudeCode":{"options":{"allowedTools":["Read"],"maxTurns":5}},"#
                    + #""systemPrompt":{"append":"Also this"}}"#
            ])
        }
    }

    /// The CLI's options reach the daemon's turn over MCP, as its prompt sends them.
    @Test(.enabled(if: mockPythonAvailable))
    func aPromptsOptionsReachTheTurnOverMCP() async throws {
        try await withIsolatedStore {
            let (id, log) = try await metaSession(load: true)
            let before = Self.lines(log).count
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let proxy = MCPServerProxy(config: .stdioHandles(server: ACPXDaemon(backend: backend)))
            try await proxy.connect()
            _ = try await DaemonClient.runPrompt(
                on: proxy, stopReason: StopReasonBox(), sessionId: id,
                content: [.object(["type": .string("text"), "text": .string("hi")])], wait: true,
                permissionMode: "approve-all", nonInteractivePermissions: "deny",
                sessionOptions: PromptSessionOptions(maxTurns: 2, systemPrompt: "Be brief"))
            await proxy.disconnect()
            await backend.releaseAll()
            #expect(Self.connects(log, after: before) == [
                #"session/load {"claudeCode":{"options":{"allowedTools":["Bash"],"maxTurns":2}},"#
                    + #""systemPrompt":"Be brief"}"#
            ])
        }
    }
}

/// What a prompt's flags send acpxd beside its `--model`, and how they go over a
/// session's own options — acpx's `sessionOptionsFromGlobalFlags` and `mergeSessionOptions`.
struct PromptSessionOptionsTests {
    private func promptOptions(_ args: [String]) async throws -> PromptSessionOptions? {
        guard case .run(let levels, _) = try Commander.parse(args + ["codex", "hi"], root: CommandTree.acpx(
            agents: ["codex"]))
        else { throw CancellationError() }
        return try await withIsolatedStore {
            let config = try ConfigLoader.load(cwd: NSTemporaryDirectory())
            return try Flags.resolveGlobalFlags(levels.first?.options ?? ScannedArgs(), config: config)
                .promptSessionOptions
        }
    }

    @Test func aPromptsFlagsAreItsSessionOptions() async throws {
        #expect(try await promptOptions([]) == nil)
        #expect(try await promptOptions(["--model", "m2"]) == nil)
        #expect(try await promptOptions(["--allowed-tools", "Read,Grep", "--max-turns", "3", "--system-prompt", "Be"])
            == PromptSessionOptions(allowedTools: ["Read", "Grep"], maxTurns: 3, systemPrompt: "Be"))
        #expect(try await promptOptions(["--append-system-prompt", "Also"])
            == PromptSessionOptions(appendSystemPrompt: "Also"))
    }

    /// A CLI from before `sessionOptions` sends a prompt's model on its own; it fills in
    /// for options that name none.
    @Test func aModelSentOnItsOwnIsTheTurns() {
        #expect(ACPXDaemon.turnOptions(nil, model: nil) == nil)
        #expect(ACPXDaemon.turnOptions(nil, model: "m2") == PromptSessionOptions(model: "m2"))
        #expect(ACPXDaemon.turnOptions(PromptSessionOptions(maxTurns: 2), model: "m2")
            == PromptSessionOptions(model: "m2", maxTurns: 2))
        #expect(ACPXDaemon.turnOptions(PromptSessionOptions(model: "m1"), model: "m2")
            == PromptSessionOptions(model: "m1"))
        #expect(ACPXDaemon.turnOptions(PromptSessionOptions(maxTurns: 2), model: nil)
            == PromptSessionOptions(maxTurns: 2))
    }

    @Test func aTurnsOptionsGoOverTheSessionsOptionByOption() throws {
        var session = SessionAcpxState.SessionOptions()
        session.model = "m1"
        session.allowedTools = ["Bash"]
        session.maxTurns = 5
        session.env = ["A": "1", "B": "2"]
        var turn = try #require(SessionAcpxState.SessionOptions(
            turnModel: "m2", PromptSessionOptions(allowedTools: ["Read"], appendSystemPrompt: "Also")))
        turn.env = ["B": "3"]
        let merged = turn.merged(over: session)
        #expect(merged.model == "m2")
        #expect(merged.allowedTools == ["Read"])
        #expect(merged.maxTurns == 5)
        #expect(merged.systemPrompt == .object(["append": .string("Also")]))
        #expect(merged.env == ["A": "1", "B": "3"])
        #expect(SessionAcpxState.SessionOptions(turnModel: nil, nil) == nil)
        #expect(SessionAcpxState.SessionOptions(turnModel: nil, PromptSessionOptions()) == nil)
    }
}
