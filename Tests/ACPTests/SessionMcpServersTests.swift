@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// A session's MCP servers as acpx has them (#245): each invocation's own — its `--mcp-config`
/// file's, else its config files' — and none kept on the record. A session's owner keeps those of
/// the prompt that started it and refuses a prompt whose MCP config is another's
/// (`QUEUE_MCP_CONFIG_CONFLICT`); a control never is, and one with no owner connects with its own.
@Suite(.serialized, .agentLane) struct SessionMcpServersTests {
    static let own = McpServerConfig(
        name: "shot", command: "/usr/local/bin/shot-mcp", args: ["--run", "42"],
        env: [.init(name: "RUN_TOKEN", value: "secret")], meta: ["run": .string("42")])
    static let other = McpServerConfig(type: "http", name: "remote", url: "https://example.com/mcp")
    private static let configured = McpServerConfig(name: "cfg", command: "cfg-tool")

    /// The config of an invocation given `--mcp-config` `path`, whose servers are `servers`.
    static func file(_ path: String, _ servers: [McpServerConfig]) -> CallerConfig {
        CallerConfig(auth: [:], mcpServers: servers, mcpConfigPath: path)
    }

    /// The config of an invocation without `--mcp-config`: its config files' servers.
    static func files(_ servers: [McpServerConfig]) -> CallerConfig {
        CallerConfig(auth: [:], mcpServers: servers)
    }

    /// The servers `newSession` is given go to the agent that creates the session, and nowhere
    /// else: the record keeps none, and a prompt that brings no config connects with the config
    /// files'.
    @Test(.enabled(if: mockPythonAvailable))
    func newSessionsServersAreTheCreatingAgentsAlone() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try writeGlobalConfig(servers: #"[{"name":"cfg","command":"cfg-tool"}]"#)
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory(), mcpServers: [Self.own])
            let stored = try String(contentsOf: ACPXPaths.sessionRecordPath(id), encoding: .utf8)
            #expect(!stored.contains("mcp_servers") && !stored.contains("shot-mcp"))

            _ = try await daemon.runPrompt(sessionId: id, text: "ping")
            let requests = try sessionRequests(log)
            #expect(requests.map(\.method) == ["session/new", "session/load"])
            #expect(requests.map(\.names) == [["shot"], ["cfg"]])
            await daemon.releaseAll()
        }
    }

    /// A session's owner keeps the servers of the prompt that started it — acpx's owner keeps its
    /// spawning CLI's config — and gives them to every agent it connects: one a later prompt of
    /// the same config needs too, on the wire as the config spells them.
    @Test(.enabled(if: mockPythonAvailable))
    func anOwnerKeepsTheServersOfThePromptThatStartedIt() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory())
            let config = Self.file("/work/mcp.json", [Self.own])
            _ = try await daemon.runPrompt(sessionId: id, text: "one", callerConfig: config)
            await daemon.evict(id)
            _ = try await daemon.runPrompt(sessionId: id, text: "two", callerConfig: config)

            let requests = try sessionRequests(log)
            #expect(requests.map(\.method) == ["session/new", "session/load", "session/load"])
            for request in requests.dropFirst() {
                let server = try #require(request.servers.first)
                #expect(request.servers.count == 1)
                #expect(server["name"] as? String == "shot" && server["args"] as? [String] == ["--run", "42"])
                #expect((server["_meta"] as? [String: String])?["run"] == "42")
                #expect((server["env"] as? [[String: String]]) == [["name": "RUN_TOKEN", "value": "secret"]])
            }
            await daemon.releaseAll()
        }
    }

    /// A prompt whose MCP config is not its session owner's is refused before anything is sent,
    /// as acpx refuses it: another `--mcp-config` file, the same file with other servers, or none —
    /// whatever the config files say. The owner's own config, spelled otherwise, is not another's.
    @Test(.enabled(if: mockPythonAvailable))
    func aPromptWhoseConfigIsNotTheOwnersIsRefused() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(
                sessionId: id, text: "one", callerConfig: Self.file("/work/a.json", [Self.configured]))
            let conflicting: [CallerConfig?] = [
                Self.file("/work/b.json", [Self.configured]), Self.file("/work/a.json", [Self.other]),
                Self.files([Self.configured]), nil
            ]
            for config in conflicting {
                await #expect(throws: QueueMcpConfigConflict()) {
                    _ = try await daemon.runPrompt(sessionId: id, text: "two", callerConfig: config)
                }
            }
            #expect(try prompts(log) == 1)

            let spelledOtherwise = McpServerConfig(type: "stdio", name: "cfg", command: "cfg-tool", args: [], env: [])
            _ = try await daemon.runPrompt(
                sessionId: id, text: "three", callerConfig: Self.file("/work/a.json", [spelledOtherwise]))
            #expect(try prompts(log) == 2)
            #expect(QueueMcpConfigConflict().localizedDescription
                == "Session queue owner uses a different MCP config; close the session before retrying")
            await daemon.releaseAll()
        }
    }

    /// An owner started without a `--mcp-config` file takes a prompt without one whatever its
    /// config files' servers — acpx fingerprints only a file given — and refuses one with a file.
    @Test(.enabled(if: mockPythonAvailable))
    func anOwnerStartedWithoutAFileComparesNoConfigFiles() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "one", callerConfig: Self.files([Self.configured]))
            _ = try await daemon.runPrompt(sessionId: id, text: "two", callerConfig: Self.files([Self.other]))
            await #expect(throws: QueueMcpConfigConflict()) {
                _ = try await daemon.runPrompt(
                    sessionId: id, text: "three", callerConfig: Self.file("/work/a.json", [Self.configured]))
            }
            #expect(try prompts(log) == 2)
            await daemon.releaseAll()
        }
    }

    /// Once the owner goes — its TTL over, or the session let go — the next prompt starts one of
    /// its own, with its own config, as acpx's next owner is spawned by the next prompt.
    @Test(.enabled(if: mockPythonAvailable))
    func theNextOwnerTakesTheConfigOfThePromptThatStartsIt() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(
                sessionId: id, text: "one", callerConfig: Self.file("/work/a.json", [Self.own]))
            #expect(try await daemon.releaseSession(sessionId: id))
            _ = try await daemon.runPrompt(sessionId: id, text: "two", callerConfig: Self.files([Self.other]))

            let requests = try sessionRequests(log)
            #expect(requests.map(\.method) == ["session/new", "session/load", "session/load"])
            #expect(requests.map(\.names) == [[], ["shot"], ["remote"]])
            await daemon.releaseAll()
        }
    }

    /// A control is never refused over its MCP config. With no owner, it connects with its own,
    /// as acpx's direct control builds its client from its own config; under an owner — its agent
    /// held or taken back — with the owner's.
    @Test(.enabled(if: mockPythonAvailable))
    func aControlConnectsWithItsOwnConfigUnlessAnOwnerHoldsTheSession() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory())
            _ = try await daemon.setMode(
                sessionId: id, modeId: "plan", client: ClientOptions(config: Self.file("/work/a.json", [Self.own])))
            _ = try await daemon.runPrompt(sessionId: id, text: "one", callerConfig: Self.files([Self.configured]))
            let another = ClientOptions(config: Self.file("/work/b.json", [Self.other]))
            _ = try await daemon.setMode(sessionId: id, modeId: "code", client: another)
            await daemon.evict(id)
            _ = try await daemon.setMode(sessionId: id, modeId: "plan", client: another)

            let requests = try sessionRequests(log)
            #expect(requests.map(\.method) == ["session/new", "session/load", "session/load", "session/load"])
            #expect(requests.map(\.names) == [[], ["shot"], ["cfg"], ["cfg"]])
            await daemon.releaseAll()
        }
    }

    /// An agent held from the session's creation runs the first prompt only when the prompt's
    /// config — its own, else the config files' — gives it the same servers: a prompt of another
    /// config gets an agent of its own, which takes the session back with its servers, as acpx's
    /// owner connects its own client (Codex review on #293).
    @Test(.enabled(if: mockPythonAvailable))
    func aHeldCreationRunsThePromptOnlyWithItsServers() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let (sameLog, otherLog) = (requestLogURL(), requestLogURL())
            let same = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: sameLog), cwd: NSTemporaryDirectory(), holdAgent: true)
            _ = try await daemon.runPrompt(sessionId: same, text: "ping", callerConfig: Self.files([]))
            #expect(try sessionRequests(sameLog).map(\.method) == ["session/new"])

            let other = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: otherLog), cwd: NSTemporaryDirectory(), holdAgent: true)
            _ = try await daemon.runPrompt(
                sessionId: other, text: "ping", callerConfig: Self.file("/b.json", [Self.other]))
            let requests = try sessionRequests(otherLog)
            #expect(requests.map(\.method) == ["session/new", "session/load"])
            #expect(requests.map(\.names) == [[], ["remote"]])
            #expect(try prompts(otherLog) == 1)

            // A caller without a config of its own has the config files' servers (none here), and
            // is compared by them as well (Codex review on #293).
            let givenLog = requestLogURL()
            let given = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: givenLog), cwd: NSTemporaryDirectory(),
                mcpServers: [Self.own], holdAgent: true)
            _ = try await daemon.runPrompt(sessionId: given, text: "ping")
            #expect(try sessionRequests(givenLog).map(\.names) == [["shot"], []])
            await daemon.releaseAll()
        }
    }

    /// The CLI reports a prompt refused over its MCP config as acpx 0.19.3 does, in each format —
    /// the session's banner first, as acpx has shown it by then.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theCLIReportsAConflictingPromptAsAcpxDoes() async throws {
        let agent = try #require(mockCommand())
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            try #"{"mcpServers":[{"name":"alpha","command":"/bin/echo"}]}"#
                .write(to: directory.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(await Self.acpx(["sessions", "new"], agent: agent, cwd: directory, backend).code == 0)
            #expect(await Self.acpx(["--mcp-config", "a.json", "prompt", "hi"], agent: agent, cwd: directory, backend)
                .code == 0)

            let message = "Session queue owner uses a different MCP config; close the session before retrying"
            let json = await Self.acpx(["--format", "json", "prompt", "again"], agent: agent, cwd: directory, backend)
            #expect(json.code == 1)
            #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":""# + message
                + #"","data":{"acpxCode":"RUNTIME","detailCode":"QUEUE_MCP_CONFIG_CONFLICT","origin":"queue","#
                + #""retryable":false,"sessionId":"unknown"}}}"# + "\n")
            let quiet = await Self.acpx(["--format", "quiet", "prompt", "again"], agent: agent, cwd: directory, backend)
            #expect(quiet.code == 1)
            #expect(quiet.err == "[acpx] error: RUNTIME QUEUE_MCP_CONFIG_CONFLICT \(message)\n")
            let text = await Self.acpx(["prompt", "again"], agent: agent, cwd: directory, backend)
            #expect(text.code == 1)
            #expect(text.err.hasPrefix("[acpx] session ") && text.err.hasSuffix("\n\(message)\n"), "\(text.err)")
            await backend.releaseAll()
        }
    }

    /// `acpx --approve-all --agent <agent> --cwd <cwd> <args>` against `backend`, the daemon running.
    private static func acpx(
        _ args: [String], agent: String, cwd: URL, _ backend: ACPXDaemonBackend
    ) async -> CLIRun {
        let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
        let capture = Console.Capture()
        let code: Int32 = await onThreadOfItsOwn {
            DaemonClient.$standIn.withValue(daemon) {
                Console.$capture.withValue(capture) {
                    runCommandLine(["--approve-all", "--agent", agent, "--cwd", cwd.path] + args)
                }
            }
        }
        return CLIRun(code: code, out: capture.out, err: capture.err)
    }

    /// acpx's `queueOwnerMcpConfigMatches`: the same `--mcp-config` file — none, or one whose
    /// servers are the same on the wire.
    @Test func whatMakesAPromptsConfigTheOwners() {
        let same = ACPXDaemonBackend.sameMcpConfig
        #expect(same(nil, nil))
        #expect(same(nil, Self.files([Self.own])))
        #expect(same(Self.files([Self.own]), Self.files([Self.other])))
        #expect(same(Self.file("/a.json", [Self.own]), Self.file("/a.json", [Self.own])))
        #expect(!same(Self.file("/a.json", [Self.own]), Self.file("/a.json", [Self.other])))
        #expect(!same(Self.file("/a.json", [Self.own]), Self.file("/b.json", [Self.own])))
        #expect(!same(Self.file("/a.json", [Self.own]), Self.files([Self.own])))
        #expect(!same(nil, Self.file("/a.json", [])))
    }

    // MARK: - Helpers

    private func writeGlobalConfig(servers: String) throws {
        try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
        try #"{"mcpServers":\#(servers)}"#
            .write(to: ACPXPaths.globalConfigPath, atomically: true, encoding: .utf8)
    }

    private func requestLogURL() -> URL {
        ACPXPaths.baseDir.appendingPathComponent("requests-\(UUID().uuidString).ndjson")
    }

    /// The mock agent — one that takes a session back — appending every `session/*` request it
    /// receives to `log`.
    private func loggedCommand(_ command: String, log: URL) -> String {
        "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_REQUEST_LOG='\(log.path)' \(command)"
    }

    private struct LoggedRequest {
        var method: String
        var servers: [[String: Any]]
        var names: [String] { servers.compactMap { $0["name"] as? String } }
    }

    /// The requests the agent received, in order.
    private func requests(_ log: URL) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    /// The requests that got a session, with their `mcpServers`, in the order the agent got them.
    private func sessionRequests(_ log: URL) throws -> [LoggedRequest] {
        try requests(log)
            .filter { ["session/new", "session/load"].contains($0["method"] as? String) }
            .map { request in
                let params = try #require(request["params"] as? [String: Any])
                return LoggedRequest(
                    method: try #require(request["method"] as? String),
                    servers: try #require(params["mcpServers"] as? [[String: Any]]))
            }
    }

    /// How many prompts reached the agent.
    private func prompts(_ log: URL) throws -> Int {
        try requests(log).filter { ($0["method"] as? String) == "session/prompt" }.count
    }
}
