@testable import ACPXCore
@testable import ACPXFlows
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// How a flow's persistent turn fails, and what it takes, in acpxd (#202, step 3b): as
/// acpx's `sendSessionDirect` fails — with the agent's error as it is, and with a permission
/// question nobody could be asked — and with the flow runner's options: its model kept with
/// the session made, and `--no-fs` given to every agent of the session.
extension DaemonToolsTests {
    /// A direct turn as a calling client's request, whose logs `client` sees; the agent's
    /// reply.
    private func directTurn(
        _ daemon: ACPXDaemonBackend, _ sessionId: String, _ text: String, permissionMode: String = "approve-all",
        fs: Bool? = nil, client: CallingClient = CallingClient(), verbose: Bool = false
    ) async throws -> String {
        let session = Session(id: UUID())
        await session.setTransport(client)
        return try await session.work { _ in
            try await daemon.runPrompt(
                sessionId: sessionId, text: text, permissionMode: permissionMode, nonInteractivePermissions: "fail",
                direct: true, fs: fs, verbose: verbose)
        }
    }

    /// The agent's error fails a direct turn as it is, as acpx's direct turn throws it: with
    /// no queue owner's detail code or origin, which the flow's CLI fills in as acpx's does,
    /// and with the ACP error, whose details the flow's error line carries.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnFailsWithTheAgentsErrorAsItIs() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
            let client = CallingClient()
            await #expect(throws: (any Error).self) {
                _ = try await directTurn(daemon, id, "fail turn", client: client)
            }
            let failure = try #require(client.failure)
            #expect(failure.outputCode == "RUNTIME")
            #expect(failure.detailCode == nil)
            #expect(failure.origin == nil)
            #expect(failure.acp.flatMap(AcpErrorPayload.init)?.details == "model overloaded")
        }
    }

    /// A direct turn refused as it would begin — the daemon stopping — fails with the refusal's
    /// own detail and origin, not a queued turn's defaults (#219 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnRefusedAsItBeginsKeepsTheRefusalsOwnCodes() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            await daemon.releaseAll()
            let client = CallingClient()
            await #expect(throws: QueueOwnerShuttingDown.self) {
                _ = try await directTurn(daemon, id, "hi", client: client)
            }
            let failure = try #require(client.failure)
            #expect(failure.detailCode == "QUEUE_OWNER_SHUTTING_DOWN")
            #expect(failure.origin == "queue")
        }
    }

    /// A direct turn that needed a permission question nobody could be asked fails with
    /// that, as acpx's client fails its prompt — though the agent ended the turn itself.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnFailsOnAPermissionNobodyCouldBeAsked() async throws {
        let command = try #require(mockCommand())
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: directory.path, holdAgent: true)
            let target = directory.appendingPathComponent("out.txt").path
            let client = CallingClient()
            await #expect(throws: PermissionPromptUnavailableError.self) {
                _ = try await directTurn(
                    daemon, id, "fs-write \(target) nobody may", permissionMode: "approve-reads", client: client)
            }
            #expect(client.failure?.outputCode == "PERMISSION_PROMPT_UNAVAILABLE")
            #expect(!FileManager.default.fileExists(atPath: target))
        }
    }

    /// The agent that makes a flow's session has its requests answered as the flow's turns
    /// are, as acpx's runner makes its client with the flow's permission mode (#219 review):
    /// a question it asks while the session opens is refused under `deny-all`, and allowed
    /// by default.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theAgentMakingAHeldSessionIsAnsweredAsTheFlowsTurnsAre() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = try #require(mockCommand())
        for (mode, expected) in [("deny-all", "reject"), (nil, "allow")] as [(String?, String)] {
            let answer = directory.appendingPathComponent("answer-\(mode ?? "default")")
            try await withIsolatedStore {
                let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
                _ = try await daemon.newSession(
                    agentCommand: "/usr/bin/env MOCK_ASK_AT_NEW='\(answer.path)' " + mock, agentArgv: nil,
                    cwd: NSTemporaryDirectory(), name: nil, mcpServers: nil, sessionOptions: nil,
                    creation: SessionCreationMode(holdAgent: true, permissionMode: mode))
                let text = try String(contentsOf: answer, encoding: .utf8)
                #expect(text.contains(expected), "\(mode ?? "default"): \(text)")
                await daemon.releaseAll()
            }
        }
    }

    /// A persistent turn stopped while the CLI reached acpxd — a cold daemon takes a while —
    /// is never sent, as acpx's direct turn checks its signal before it prompts, and the
    /// session's kept agent is let go (#219 review). acpxd here is one in process: the
    /// session's turn slot is never asked for — the turn is not sent, and the kept agent, idle,
    /// is let go without it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPersistentTurnStoppedAsItReachesTheDaemonIsNotSent() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = directory.appendingPathComponent("requests.log")
        let command = "/usr/bin/env MOCK_REQUEST_LOG='\(requests.path)' " + (try #require(mockCommand()))
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let config = try ConfigLoader.load(cwd: NSTemporaryDirectory())
            let sessions = FlowAgentSessions(
                flags: try Flags.resolveGlobalFlags(ScannedArgs(), config: config), config: config,
                permission: .approveAll, permissionRules: nil, mcpServers: [])
            let (creating, attempt) = (
                FlowAttempt(nodeId: "ask", attemptId: "ask-1", startedAt: nowISO(), timeoutMs: nil),
                FlowAttempt(nodeId: "ask", attemptId: "ask-2", startedAt: nowISO(), timeoutMs: nil))
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            let agent = FlowAgent(agentName: "mock", agentCommand: command, agentArgv: nil, cwd: NSTemporaryDirectory())
            let id = try await DaemonClient.$standIn.withValue(daemon) {
                try await sessions.createPersistent(
                    agent: agent, name: "flow-main", control: FlowTurnControl(attempt: creating)).acpxRecordId
            }
            let turn = FlowPersistentTurn(
                recordId: id, prompt: [.text("hi")], onMessage: { _, _ in }, control: FlowTurnControl(attempt: attempt))
            let slots = Lines()
            await backend.turnQueue.setBeforeAcquire { recordId in slots.add(recordId) }
            let stopAsItIsSent: @Sendable () -> Void = { attempt.cancel(FlowTimeoutError(timeoutMs: 10)) }
            await #expect(throws: FlowTimeoutError.self) {
                try await DaemonClient.$standIn.withValue(daemon) {
                    try await FlowAgentSessions.$beforeSending.withValue(stopAsItIsSent) {
                        try await sessions.runPersistent(turn)
                    }
                }
            }
            #expect(slots.all.isEmpty)
            let logged = (try? String(contentsOf: requests, encoding: .utf8)) ?? ""
            #expect(!logged.contains("session/prompt"), "\(logged)")
            #expect(await !backend.sessionStatus(sessionId: id).live)
            await backend.releaseAll()
        }
    }

    /// A cancel that names a direct turn before acpxd has begun it calls the turn off: it
    /// ends as it begins, its prompt never sent, however the cancel and the turn crossed —
    /// and its agent let go, as acpx's flow runner closes the client a stopped direct turn
    /// would prompt on (#219 review). A turn with another name runs.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnCalledOffBeforeItBeganIsNeverSent() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = directory.appendingPathComponent("requests.log")
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_REQUEST_LOG='\(requests.path)' "
            + (try #require(mockCommand()))
        let logged = { (try? String(contentsOf: requests, encoding: .utf8)) ?? "" }
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "stopped") == false)
            let calledOff = try await daemon.runPrompt(
                sessionId: id, text: "hi", permissionMode: "approve-all", direct: true, turnToken: "stopped")
            #expect(calledOff.isEmpty)
            #expect(!logged().contains("session/prompt"), "\(logged())")
            // Its agent went with it, as acpx closes the client it was handed (#219 review): the
            // next turn takes the session back.
            #expect(await !daemon.sessionStatus(sessionId: id).live)
            let answered = try await daemon.runPrompt(
                sessionId: id, text: "hi", permissionMode: "approve-all", direct: true, turnToken: "next")
            #expect(answered.contains("You said: hi"), "\(answered)")
            #expect(logged().contains("session/load") && logged().contains("session/prompt"), "\(logged())")
        }
    }

    /// A creation whose answer the CLI never gets, or gets as a failure, is called off, the
    /// attempt stopped or not: the record's id, which the answer names, would never be learned
    /// otherwise (#219 review). Here acpxd cannot start the agent, and keeps the call-off it gets.
    @Test(.timeLimit(.minutes(1)))
    func aCreationThatFailsIsCalledOff() async throws {
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let config = try ConfigLoader.load(cwd: NSTemporaryDirectory())
            let sessions = FlowAgentSessions(
                flags: try Flags.resolveGlobalFlags(ScannedArgs(), config: config), config: config,
                permission: .approveAll, permissionRules: nil, mcpServers: [])
            let attempt = FlowAttempt(nodeId: "ask", attemptId: "ask-1", startedAt: nowISO(), timeoutMs: nil)
            let agent = FlowAgent(
                agentName: "gone", agentCommand: "/nonexistent/agent", agentArgv: nil, cwd: NSTemporaryDirectory())
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            await #expect(throws: (any Error).self) {
                try await DaemonClient.$standIn.withValue(daemon) {
                    _ = try await sessions.createPersistent(
                        agent: agent, name: "flow-main", control: FlowTurnControl(attempt: attempt))
                }
            }
            #expect(await backend.calledOffCreations.count == 1)
        }
    }

    /// A flow lets go only of the agent its own creation made: after another creation took its
    /// session's place under the same id, neither a first turn that failed nor the run's end
    /// lets go of the agent that replaced it (#219 review). The mock gives every session one id.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aFlowLetsGoOnlyOfTheAgentItMade() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let config = try ConfigLoader.load(cwd: NSTemporaryDirectory())
            let sessions = FlowAgentSessions(
                flags: try Flags.resolveGlobalFlags(ScannedArgs(), config: config), config: config,
                permission: .approveAll, permissionRules: nil, mcpServers: [])
            let (creating, stopped) = (
                FlowAttempt(nodeId: "ask", attemptId: "ask-1", startedAt: nowISO(), timeoutMs: nil),
                FlowAttempt(nodeId: "ask", attemptId: "ask-2", startedAt: nowISO(), timeoutMs: nil))
            stopped.cancel(FlowTimeoutError(timeoutMs: 10))
            let agent = FlowAgent(agentName: "mock", agentCommand: command, agentArgv: nil, cwd: NSTemporaryDirectory())
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            try await DaemonClient.$standIn.withValue(daemon) {
                let id = try await sessions.createPersistent(
                    agent: agent, name: "flow-main", control: FlowTurnControl(attempt: creating)).acpxRecordId
                // Another flow's creation takes the session's place under the same id.
                let replaced = try await backend.newSession(
                    agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
                #expect(replaced == id)
                let kept = try #require(await backend.live[id]?.agent)
                await #expect(throws: FlowTimeoutError.self) {
                    try await sessions.runPersistent(FlowPersistentTurn(
                        recordId: id, prompt: [.text("hi")], onMessage: { _, _ in },
                        control: FlowTurnControl(attempt: stopped)))
                }
                try await sessions.releasePersistent(id)
                #expect(await backend.live[id]?.agent === kept)
                #expect(await !kept.connection.isClosed)
            }
            await backend.releaseAll()
        }
    }

    /// A flow run with `--mcp-config` gives its persistent sessions the file's servers, as
    /// acpx's runner gives every client the invocation's (#219 review). acpxd here is one
    /// in process.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aFlowsOwnMcpServersReachItsPersistentSession() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = directory.appendingPathComponent("requests.log")
        let mcp = directory.appendingPathComponent("mcp.json")
        try #"{"mcpServers":[{"name":"flow-tools","command":"true"}]}"#
            .write(to: mcp, atomically: true, encoding: .utf8)
        let command = "/usr/bin/env MOCK_REQUEST_LOG='\(requests.path)' " + (try #require(mockCommand()))
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let config = try ConfigLoader.load(cwd: directory.path, mcpConfigPath: mcp.path)
            let sessions = FlowAgentSessions(
                flags: try Flags.resolveGlobalFlags(ScannedArgs(), config: config), config: config,
                permission: .approveAll, permissionRules: nil, mcpServers: try config.mcpServerSpecs())
            let attempt = FlowAttempt(nodeId: "ask", attemptId: "ask-1", startedAt: nowISO(), timeoutMs: nil)
            let agent = FlowAgent(agentName: "mock", agentCommand: command, agentArgv: nil, cwd: directory.path)
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            _ = try await DaemonClient.$standIn.withValue(daemon) {
                try await sessions.createPersistent(
                    agent: agent, name: "flow-main", control: FlowTurnControl(attempt: attempt))
            }
            let logged = (try? String(contentsOf: requests, encoding: .utf8)) ?? ""
            #expect(logged.contains("session/new") && logged.contains("flow-tools"), "\(logged)")
            await backend.releaseAll()
        }
    }

    /// A flow's `--auth-policy` reaches its persistent session — the agent that makes it and
    /// the one a later turn takes it back with — as acpx's runner gives every client the
    /// flow's (#219 review): under `fail`, an agent that advertises a sign-in none of the
    /// credentials match is refused, where the configured `skip` lets it go on.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aFlowsAuthPolicyReachesItsPersistentSession() async throws {
        let command = "/usr/bin/env MOCK_AUTH_METHODS=token MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await #expect(throws: AuthPolicyError.self) {
                _ = try await daemon.newSession(
                    agentCommand: command, agentArgv: nil, cwd: NSTemporaryDirectory(), name: nil, mcpServers: nil,
                    sessionOptions: nil, creation: SessionCreationMode(holdAgent: true, authPolicy: "fail"))
            }
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            await #expect(throws: AuthPolicyError.self) {
                _ = try await daemon.runPrompt(
                    sessionId: id, text: "hi", permissionMode: "approve-all", direct: true, authPolicy: "fail")
            }
        }
    }

    /// A flow's persistent session is made, and taken back by a later turn, with the flow's
    /// config — its `auth` and its MCP servers — as acpx's runner gives every client of the
    /// flow the invocation's (`config.auth`, `config.mcpServers`), read once as the run began:
    /// not the config of a node's cwd that has one of its own, nor the flow's own file as it
    /// changes meanwhile (#219 review). Under the flow's `fail`, the agent's sign-in is found
    /// only in the flow's config as the run began.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aFlowsConfigReachesItsPersistentSession() async throws {
        let flowDirectory = try Self.scratchDirectory()
        let nodeDirectory = try Self.scratchDirectory()
        defer { for directory in [flowDirectory, nodeDirectory] { try? FileManager.default.removeItem(at: directory) } }
        try #"{"authPolicy":"fail","auth":{"token":"secret"},"mcpServers":[{"name":"flow-tools","command":"true"}]}"#
            .write(to: flowDirectory.appendingPathComponent(".acpxrc.json"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":[{"name":"node-tools","command":"true"}]}"#
            .write(to: nodeDirectory.appendingPathComponent(".acpxrc.json"), atomically: true, encoding: .utf8)
        let requests = flowDirectory.appendingPathComponent("requests.log")
        let command = "/usr/bin/env MOCK_AUTH_METHODS=token MOCK_LOAD_SESSION=ok MOCK_REQUEST_LOG='\(requests.path)' "
            + (try #require(mockCommand()))
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let config = try ConfigLoader.load(cwd: flowDirectory.path)
            let sessions = FlowAgentSessions(
                flags: try Flags.resolveGlobalFlags(ScannedArgs(), config: config), config: config,
                permission: .approveAll, permissionRules: nil, mcpServers: try config.mcpServerSpecs())
            let attempt = FlowAttempt(nodeId: "ask", attemptId: "ask-1", startedAt: nowISO(), timeoutMs: nil)
            let agent = FlowAgent(agentName: "mock", agentCommand: command, agentArgv: nil, cwd: nodeDirectory.path)
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            try await DaemonClient.$standIn.withValue(daemon) {
                let record = try await sessions.createPersistent(
                    agent: agent, name: "flow-main", control: FlowTurnControl(attempt: attempt))
                // A node changes the flow's config: nothing of it reaches the run's sessions.
                try #"{"mcpServers":[{"name":"changed-tools","command":"true"}]}"#
                    .write(to: flowDirectory.appendingPathComponent(".acpxrc.json"), atomically: true, encoding: .utf8)
                // The first turn takes the kept agent; the second takes the session back.
                for _ in 0..<2 {
                    try await sessions.runPersistent(FlowPersistentTurn(
                        recordId: record.acpxRecordId, prompt: [.text("hi")], onMessage: { _, _ in },
                        control: FlowTurnControl(attempt: attempt)))
                }
            }
            let logged = (try? String(contentsOf: requests, encoding: .utf8)) ?? ""
            let opened = logged.split(separator: "\n")
                .filter { $0.contains("session/new") || $0.contains("session/load") }
            #expect(opened.count == 2, "\(logged)")
            let flowsOwn = { (line: Substring) in
                line.contains("flow-tools") && !line.contains("node-tools") && !line.contains("changed-tools")
            }
            #expect(opened.allSatisfy(flowsOwn), "\(logged)")
            await backend.releaseAll()
        }
    }

    /// A flow's persistent turn sends acpxd each of its options: the CLI calls `runPrompt`
    /// untyped (``DaemonClient/promptArguments(sessionId:content:wait:permissionMode:nonInteractivePermissions:permissionPolicy:terminalOutputCeiling:model:sessionOptions:limits:mode:)``),
    /// and `verbose` was once left out of the call.
    @Test func aDirectTurnsOptionsGoWithItsCall() throws {
        let arguments = try DaemonClient.promptArguments(
            sessionId: "s", content: [], wait: true, permissionMode: "approve-all", nonInteractivePermissions: "deny",
            permissionPolicy: nil, terminalOutputCeiling: 0, model: nil, sessionOptions: nil, limits: nil,
            mode: PromptTurnMode(
                streamWire: true, direct: true, fs: false, authPolicy: "fail", turnToken: "t",
                callerConfig: CallerConfig(auth: ["token": "secret"], mcpServers: []), verbose: true,
                environment: ["FLOWVAR": "set"]))
        #expect(arguments["streamWire"] == .bool(true))
        #expect(arguments["direct"] == .bool(true))
        #expect(arguments["fs"] == .bool(false))
        #expect(arguments["authPolicy"] == .string("fail"))
        #expect(arguments["turnToken"] == .string("t"))
        #expect(try arguments["callerConfig"]?.decoded(CallerConfig.self).auth == ["token": "secret"])
        #expect(arguments["verbose"] == .bool(true))
        #expect(arguments["environment"] == .object(["FLOWVAR": .string("set")]))
    }

    /// What `client` was sent of the agent's own stderr (``AgentStderrEvent``): acpx's
    /// `[acpx]` lines among it left out (``diagnostics(of:)``).
    static func stderr(of client: CallingClient) -> String {
        relayedLines(of: client).filter { !$0.hasPrefix("[acpx] ") }.map { $0 + "\n" }.joined()
    }

    /// acpx's own `[acpx]` lines among what `client` was sent of the agent's stderr (#221), a
    /// pid written `<PID>` and a timing's milliseconds `<MS>`.
    static func diagnostics(of client: CallingClient) -> [String] {
        relayedLines(of: client).filter { $0.hasPrefix("[acpx] ") }.map { line in
            line.replacingOccurrences(of: #"pid \d+"#, with: "pid <PID>", options: .regularExpression)
                .replacingOccurrences(of: #"=\d+(\.\d+)?ms$"#, with: "=<MS>ms", options: .regularExpression)
        }
    }

    private static func relayedLines(of client: CallingClient) -> [String] {
        let chunks = client.logs.compactMap { try? $0.decoded(AgentStderrEvent.self) }.compactMap(\.bytes)
        return String(decoding: chunks.reduce(Data(), +), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The options' model is kept with a session made for a flow's first turn, with the
    /// rest of them, as acpx's `createSessionWithClient` records its options. The session's
    /// current model stays the agent's, as acpx 0.19.3's `sessions new --model` leaves it on
    /// this agent, whose `model` option offers the one asked for.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aHeldSessionKeepsItsModelInItsOptions() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-agent.py")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: "'\(python)' '\(fixture.path)'", cwd: NSTemporaryDirectory(),
                sessionOptions: PromptSessionOptions(model: "b", maxTurns: 2), holdAgent: true)
            let acpx = try #require(SessionStore.loadRecord(id)?.acpx)
            #expect(acpx.sessionOptions?.model == "b")
            #expect(acpx.sessionOptions?.maxTurns == 2)
            #expect(acpx.currentModelId == "a")
            await daemon.releaseAll()
        }
    }

    /// `--no-fs` reaches every agent of a flow's session — the one that made it, for the
    /// first turn, and the one a later turn takes it back with — as acpx's flow runner
    /// gives `fs` to every client it makes. The record keeps none of it: a turn without it
    /// is offered the filesystem again.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func noFsReachesEveryAgentOfAFlowsSession() async throws {
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("read-me.txt")
        try "the text".write(to: file, atomically: true, encoding: .utf8)
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, cwd: directory.path, holdAgent: true, fs: false)
            #expect(SessionStore.loadRecord(id)?.acpx?.clientCapabilities == nil)
            let refused = #"error: "Method not found": fs/read_text_file"#
            #expect(try await directTurn(daemon, id, "fs-read \(file.path)", fs: false) == refused)
            #expect(try await directTurn(daemon, id, "fs-read \(file.path)", fs: false) == refused)
            #expect(try await directTurn(daemon, id, "fs-read \(file.path)") == "the text")
        }
    }
}
