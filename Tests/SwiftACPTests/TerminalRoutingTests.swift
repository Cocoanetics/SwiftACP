@testable import SwiftACP
import Foundation
import JSONFoundation
import Testing

/// How the client routes the agent's `terminal/*` requests (#82): refused as acpx
/// refuses them without the capability, gated per turn by the permission mode, counted
/// in the turn's permission stats, and run on the connection's terminal handler in the
/// session's directory. Expected shapes are acpx 0.19.1's.
@Suite(.timeLimit(.minutes(1)))
struct TerminalRoutingTests {
    /// A terminal handler that runs nothing: it records what reached it.
    actor RecordingTerminals: ACPTerminalHandler {
        private(set) var created: [CreateTerminalRequest] = []
        private(set) var released: [String] = []
        private var shutDown = false
        private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

        func createTerminal(_ request: CreateTerminalRequest) -> CreateTerminalResponse {
            created.append(request)
            return CreateTerminalResponse(terminalId: "t\(created.count)")
        }

        func terminalOutput(_ request: TerminalOutputRequest) -> TerminalOutputResponse {
            TerminalOutputResponse(output: "out:\(request.terminalId)", truncated: false)
        }

        func waitForTerminalExit(_ request: WaitForTerminalExitRequest) -> WaitForTerminalExitResponse {
            WaitForTerminalExitResponse(exitCode: 0)
        }

        func killTerminal(_ request: KillTerminalRequest) -> KillTerminalResponse { KillTerminalResponse() }

        func releaseTerminal(_ request: ReleaseTerminalRequest) -> ReleaseTerminalResponse {
            released.append(request.terminalId)
            return ReleaseTerminalResponse()
        }

        func shutdown() {
            shutDown = true
            shutdownWaiters.forEach { $0.resume() }
            shutdownWaiters = []
        }

        /// Suspend until ``shutdown()`` has been called.
        func waitForShutdown() async {
            if shutDown { return }
            await withCheckedContinuation { shutdownWaiters.append($0) }
        }
    }

    /// An agent whose turn runs `script` against the client and says what it returned.
    struct ScriptedAgent: ACPAgentHandler {
        let script: @Sendable (ACPServerSession) async -> String

        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(agentInfo: Implementation(name: "terminal-probe", version: "1.0"))
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: "terminal-session")
        }

        func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
            await session.sendText(await script(session))
            return PromptResponse(stopReason: .endTurn)
        }
    }

    /// An error the client answered, as `code|message|data`.
    static func describe(_ error: Error) -> String {
        guard let error = error as? JSONRPCErrorBody else { return "\(error)" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? error.data.map { String(decoding: try encoder.encode($0), as: UTF8.self) }) ?? nil
        return "\(error.code)|\(error.message)|\(data ?? "")"
    }

    struct Turn {
        var reply: String
        var stats: PermissionStats
    }

    /// One turn of `script` over a loopback, the client serving terminals through
    /// `terminals` under `handlers`.
    func turn(
        cwd: String = "/work", capabilities: ClientCapabilities = .acpxWithTerminals,
        handlers: ACPClientHandlers = ACPClientHandlers(), terminals: (any ACPTerminalHandler)?,
        script: @escaping @Sendable (ACPServerSession) async -> String
    ) async throws -> Turn {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: ScriptedAgent(script: script), transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(transport: clientTransport, handlers: handlers)
        await client.setTerminalHandler(terminals)
        await client.start()
        _ = try await client.initialize(capabilities: capabilities, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: cwd))
        let (subscriptionId, stream) = await client.makeSubscription()
        let consumer = Task { () -> String in
            var text = ""
            for await note in stream {
                if case .agentMessageChunk(let block) = note.update, let chunk = block.text { text += chunk }
            }
            return text
        }
        _ = try await client.prompt(PromptRequest(sessionId: session.sessionId, prompt: [.text("go")]))
        await client.endSubscription(subscriptionId)
        let reply = await consumer.value
        let stats = await client.permissionStats(for: session.sessionId)
        await client.close()
        serverTask.cancel()
        return Turn(reply: reply, stats: stats)
    }

    static let createEcho: @Sendable (ACPServerSession) async -> String = { session in
        do {
            return "ok:" + (try await session.createTerminal(command: "echo", args: ["a b", "c\"d"]))
        } catch {
            return describe(error)
        }
    }

    // MARK: - Not advertised, not served

    /// acpx registers the terminal methods only with the capability: an agent calling
    /// one anyway hears the ACP SDK's method-not-found.
    @Test func withoutTheCapabilityTheMethodIsNotFound() async throws {
        let terminals = RecordingTerminals()
        let turn = try await turn(capabilities: .headlessController, terminals: terminals, script: Self.createEcho)
        #expect(turn.reply == #"-32601|"Method not found": terminal/create|{"method":"terminal/create"}"#)
        #expect(await terminals.created.isEmpty)
    }

    @Test func withoutAHandlerTheMethodIsNotFound() async throws {
        let turn = try await turn(terminals: nil, script: Self.createEcho)
        #expect(turn.reply == #"-32601|"Method not found": terminal/create|{"method":"terminal/create"}"#)
    }

    // MARK: - The turn's permission gate

    @Test func approveAllRunsTheCommandInTheSessionsDirectory() async throws {
        let terminals = RecordingTerminals()
        let turn = try await turn(
            cwd: "/work/repo", handlers: .standard(permission: .approveAll, terminal: .none),
            terminals: terminals, script: Self.createEcho)
        #expect(turn.reply == "ok:t1")
        let created = try #require(await terminals.created.first)
        #expect(created.command == "echo" && created.args == ["a b", "c\"d"])
        #expect(created.cwd == "/work/repo")
        // Upstream counts a delegated operation only when it is refused.
        #expect(turn.stats == PermissionStats())
    }

    /// A `cwd` the agent names is kept.
    @Test func aRequestedDirectoryIsKept() async throws {
        let terminals = RecordingTerminals()
        _ = try await turn(terminals: terminals) { session in
            (try? await session.createTerminal(command: "pwd", cwd: "/elsewhere")) ?? "failed"
        }
        #expect(await terminals.created.first?.cwd == "/elsewhere")
    }

    /// `--deny-all` refuses in acpx's shape, never reaches the handler, and counts.
    @Test func denyAllRefusesTheCommand() async throws {
        let terminals = RecordingTerminals()
        let turn = try await turn(
            handlers: .standard(permission: .denyAll, terminal: .none), terminals: terminals,
            script: Self.createEcho)
        #expect(turn.reply == #"-32603|Internal error|{"details":"Permission denied for terminal/create"}"#)
        #expect(await terminals.created.isEmpty)
        #expect(turn.stats.denied == 1)
        #expect(turn.stats.deniedEverything)
    }

    /// `--approve-reads` with no terminal to ask on: refused under the default `deny`…
    @Test func approveReadsWithoutATerminalRefuses() async throws {
        let turn = try await turn(
            handlers: .standard(permission: .approveReads, terminal: .none), terminals: RecordingTerminals(),
            script: Self.createEcho)
        #expect(turn.reply == #"-32603|Internal error|{"details":"Permission denied for terminal/create"}"#)
        #expect(turn.stats.denied == 1)
    }

    /// …and refused as unanswerable under `fail`, which fails the turn once over.
    @Test func approveReadsUnderFailCannotBeAnswered() async throws {
        let turn = try await turn(
            handlers: .standard(permission: .approveReads, nonInteractivePermissions: .fail, terminal: .none),
            terminals: RecordingTerminals(), script: Self.createEcho)
        #expect(turn.reply
            == #"-32603|Internal error|{"details":"Permission prompt unavailable in non-interactive mode"}"#)
        #expect(turn.stats.cancelled == 1)
        #expect(turn.stats.promptUnavailable)
    }

    /// The confirmation is asked with acpx's command line, and a no refuses.
    @Test func theConfirmationSeesAcpxsCommandLine() async throws {
        let asked = Asked()
        let handlers = ACPClientHandlers.standard(
            permission: .approveReads, confirmTerminal: { await asked.record($0) }, terminal: .none)
        let turn = try await turn(handlers: handlers, terminals: RecordingTerminals(), script: Self.createEcho)
        #expect(await asked.lines == [#"echo "a b" "c\"d""#])
        #expect(turn.reply.hasSuffix("Permission denied for terminal/create\"}"))
    }

    actor Asked {
        var lines: [String] = []
        func record(_ line: String) -> Bool {
            lines.append(line)
            return false
        }
    }

    /// The question on the terminal is acpx's, word for word.
    @Test func theTerminalQuestionIsAcpxs() async throws {
        let terminal = TerminalPermissionPromptTests.Terminal()
        terminal.type("y\n")
        let approval = TerminalApproval(policy: .approveReads, terminal: terminal.prompt)
        try await approval.authorize(CreateTerminalRequest(sessionId: "s", command: "echo", args: ["a b"]))
        await terminal.waitFor("(y/N) ")
        #expect(terminal.output == "\n[permission] Allow terminal command \"echo \"a b\"\"? (y/N) ")
    }

    // MARK: - The other methods

    @Test func everyMethodReachesTheHandler() async throws {
        let terminals = RecordingTerminals()
        let turn = try await turn(terminals: terminals) { session in
            do {
                let id = try await session.createTerminal(command: "true")
                let output = try await session.terminalOutput(terminalId: id)
                let exit = try await session.waitForTerminalExit(terminalId: id)
                try await session.killTerminal(terminalId: id)
                try await session.releaseTerminal(terminalId: id)
                return "\(output.output) \(exit.exitCode ?? -1)"
            } catch {
                return Self.describe(error)
            }
        }
        #expect(turn.reply == "out:t1 0")
        #expect(await terminals.released == ["t1"])
    }

    /// Params the schema rejects are the ACP SDK's `Invalid params`.
    @Test func malformedParamsAreInvalidParams() async throws {
        let client = ACPAgentConnection(transport: LoopbackTransport.pair().0)
        await client.setTerminalHandler(RecordingTerminals())
        let result = await client.handleIncomingRequest(
            method: "terminal/output", params: .object(["sessionId": .string("s"), "terminalId": .null]))
        guard case .failure(let error) = result else { Issue.record("served"); return }
        #expect(error.code == -32602 && error.message == "Invalid params")
    }

    // MARK: - Lifetime

    /// A confirmation that holds until the test lets it answer yes.
    actor Gate {
        private var asked = false
        private var askedWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        func confirm() async -> Bool {
            asked = true
            askedWaiters.forEach { $0.resume() }
            askedWaiters = []
            await withCheckedContinuation { openWaiters.append($0) }
            return true
        }

        func waitUntilAsked() async {
            if asked { return }
            await withCheckedContinuation { askedWaiters.append($0) }
        }

        func open() {
            openWaiters.forEach { $0.resume() }
            openWaiters = []
        }
    }

    /// A command approved only after the connection ended does not start: its
    /// terminals were released, and it would outlive them. acpx rechecks its control
    /// authority after asking and answers `Request cancelled`.
    @Test func aCommandApprovedAfterTheConnectionEndedDoesNotStart() async throws {
        let gate = Gate()
        let terminals = RecordingTerminals()
        let handlers = ACPClientHandlers.standard(
            permission: .approveReads, confirmTerminal: { _ in await gate.confirm() }, terminal: .none)
        let client = ACPAgentConnection(transport: LoopbackTransport.pair().0, handlers: handlers)
        await client.setTerminalHandler(terminals)
        let create = Task {
            await client.handleIncomingRequest(
                method: "terminal/create", params: .object(["sessionId": .string("s"), "command": .string("true")]))
        }
        await gate.waitUntilAsked()
        await client.shutDownTerminals()
        await gate.open()
        guard case .failure(let error) = await create.value else { Issue.record("started"); return }
        #expect(error.code == -32800 && error.message == "Request cancelled")
        #expect(await terminals.created.isEmpty)
    }

    /// Terminals are released when the connection ends, as acpx retires them when its
    /// client closes.
    @Test func closingTheConnectionShutsTheTerminalsDown() async throws {
        let terminals = RecordingTerminals()
        _ = try await turn(terminals: terminals) { _ in "done" }
        await terminals.waitForShutdown()
    }
}

extension ClientCapabilities {
    /// File access and terminals, whether or not this platform runs them itself.
    static let acpxWithTerminals = ClientCapabilities(
        fs: FileSystemCapability(readTextFile: true, writeTextFile: true), terminal: true)
}
