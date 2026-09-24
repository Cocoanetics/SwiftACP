@testable import SwiftACP
import Foundation
import JSONFoundation
import Testing

/// Cancelling a turn as acpx's client cancels it (#109): one `session/cancel` for the
/// prompt in flight however often the turn is cancelled, and the agent's requests of the
/// turn answered as cancelled from then on — `fs/*` and `terminal/*` with `Request
/// cancelled`, a permission question `cancelled` — as acpx 0.19.1 answered them.
@Suite(.timeLimit(.minutes(1)))
struct TurnCancelTests {
    /// An agent whose turn asks what `ask` asks once the turn is cancelled, then waits
    /// for `end` — when given — before it ends. It asks outside the turn's task, which
    /// the server cancels with the turn.
    struct HeldTurnAgent: ACPAgentHandler {
        var started = Signal()
        var cancelled = Signal()
        var end: Signal?
        var ask: @Sendable (ACPServerSession) async -> Void = { _ in }

        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(agentInfo: Implementation(name: "held", version: "1.0"))
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: "held-session")
        }

        func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
            started.fire()
            await cancelled.wait()
            let ask = ask
            await Task.detached { await ask(session) }.value
            await end?.wait()
            return PromptResponse(stopReason: .cancelled)
        }

        func cancel(sessionId: SessionId) async {
            cancelled.fire()
        }
    }

    /// A client connected to `agent`, with a session open.
    struct Connected {
        let client: ACPAgentConnection
        let session: SessionId
        let server: Task<Void, any Error>

        func close() async {
            await client.close()
            server.cancel()
        }
    }

    private static func connect(
        _ agent: some ACPAgentHandler, handlers: ACPClientHandlers = ACPClientHandlers()
    ) async throws -> Connected {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: agent, transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(transport: clientTransport, handlers: handlers)
        await client.start()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: NSTemporaryDirectory()))
        return Connected(client: client, session: session.sessionId, server: serverTask)
    }

    private static func describe(_ error: any Error) -> String {
        (error as? JSONRPCErrorBody).map { "\($0.code) \($0.message)" } ?? "\(error)"
    }

    /// However often a turn is cancelled while its prompt is in flight, one
    /// `session/cancel` goes out; with no prompt in flight, each cancel sends one.
    @Test func aTurnIsCancelledOnceHoweverOftenItIsAsked() async throws {
        let agent = HeldTurnAgent(end: Signal())
        let connected = try await Self.connect(agent)
        let (client, session) = (connected.client, connected.session)
        let sent = Recorder<String>()
        await client.setWireObserver { line in
            if line.contains("\"method\":\"session/cancel\"") { sent.append(line) }
        }
        let turn = Task { try await client.prompt(PromptRequest(sessionId: session, prompt: [.text("go")])) }
        await agent.started.wait()
        try await client.cancel(sessionId: session)
        try await client.cancel(sessionId: session)
        #expect(sent.values.count == 1)
        agent.end?.fire()
        #expect(try await turn.value.stopReason == .cancelled)
        try await client.cancel(sessionId: session)
        #expect(sent.values.count == 2)
        await connected.close()
    }

    /// Once the turn is cancelled, what the agent asks of it is not served: a read and a
    /// command fail as `Request cancelled`, and a permission question is answered
    /// `cancelled` — not counted, as it came after the cancel.
    @Test func whatACancelledTurnAsksIsAnsweredAsCancelled() async throws {
        let file = NSTemporaryDirectory() + "cancel-\(UUID().uuidString).txt"
        try "hi".write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let answers = Recorder<String>()
        let agent = HeldTurnAgent(ask: { session in
            do {
                answers.append("read: " + (try await session.readTextFile(path: file)))
            } catch {
                answers.append("read: " + Self.describe(error))
            }
            do {
                answers.append("terminal: " + (try await session.createTerminal(command: "echo")))
            } catch {
                answers.append("terminal: " + Self.describe(error))
            }
            let permission = try? await session.requestPermission(
                toolCall: ToolCallUpdate(toolCallId: "t"),
                options: [PermissionOption(optionId: "yes", name: "Yes", kind: .allowOnce)])
            answers.append("permission: " + (permission.map { "\($0.outcome)" } ?? "failed"))
        })
        let terminals = TerminalRoutingTests.RecordingTerminals()
        let connected = try await Self.connect(agent, handlers: .standard(permission: .approveAll))
        let (client, session) = (connected.client, connected.session)
        await client.setFileSystemAccess(.unrestricted)
        await client.setTerminalHandler(terminals)
        let turn = Task { try await client.prompt(PromptRequest(sessionId: session, prompt: [.text("go")])) }
        await agent.started.wait()
        try await client.cancel(sessionId: session)
        #expect(try await turn.value.stopReason == .cancelled)
        #expect(answers.values == [
            "read: -32800 Request cancelled", "terminal: -32800 Request cancelled", "permission: cancelled"
        ])
        #expect(await terminals.created.isEmpty)
        #expect(await client.permissionStats(for: session).requested == 0)
        await connected.close()
    }

    /// A question still being answered when the turn is cancelled is answered
    /// `cancelled` at once, and counted so — however its handler answers later.
    @Test func aQuestionBeingAnsweredIsCancelledWithItsTurn() async throws {
        struct AskingAgent: ACPAgentHandler {
            let outcome: Recorder<String>
            func initialize(_ request: InitializeRequest) async -> InitializeResponse {
                InitializeResponse(agentInfo: Implementation(name: "asking", version: "1.0"))
            }
            func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
                NewSessionResponse(sessionId: "asking-session")
            }
            func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
                // Outside the turn's task, which the server cancels with the turn.
                let response = try await Task.detached {
                    try await session.requestPermission(
                        toolCall: ToolCallUpdate(toolCallId: "t"),
                        options: [PermissionOption(optionId: "yes", name: "Yes", kind: .allowOnce)])
                }.value
                outcome.append("\(response.outcome)")
                return PromptResponse(stopReason: .cancelled)
            }
        }
        let (asked, answer) = (Signal(), Signal())
        let outcome = Recorder<String>()
        let handlers = ACPClientHandlers(requestPermission: { request in
            asked.fire()
            await answer.wait()
            return .selected(request.options[0].optionId)
        })
        let connected = try await Self.connect(AskingAgent(outcome: outcome), handlers: handlers)
        let (client, session) = (connected.client, connected.session)
        let turn = Task { try await client.prompt(PromptRequest(sessionId: session, prompt: [.text("go")])) }
        await asked.wait()
        try await client.cancel(sessionId: session)
        #expect(try await turn.value.stopReason == .cancelled)
        #expect(outcome.values == ["cancelled"])
        let stats = await client.permissionStats(for: session)
        #expect(stats.cancelled == 1 && stats.approved == 0)
        answer.fire()
        await connected.close()
    }
}
