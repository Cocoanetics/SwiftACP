#if os(macOS) || os(Linux)
@testable import SwiftACP
import Foundation
import JSONFoundation
import JSONRPCPeer
import Testing

/// What a prompt does with the agent's requests at its answer and at a cancel, as acpx
/// 0.19.1's client does (#130). The requests it owns — a permission question, a file read
/// or write, starting a command — end with it: one still open is answered cancelled, and
/// one served only afterwards is answered so without being served. The rest of a
/// command's requests go on, and nothing waits for them.
struct RequestOwnershipTests {
    /// What the agent was told, by the id of each request it made.
    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [JSONRPCID: JSONRPCMessage] = [:]
        private var waiters: [JSONRPCID: [CheckedContinuation<JSONRPCMessage, Never>]] = [:]

        func record(_ id: JSONRPCID, _ message: JSONRPCMessage) {
            let waiting = lock.withLock {
                answers[id] = message
                return waiters.removeValue(forKey: id) ?? []
            }
            waiting.forEach { $0.resume(returning: message) }
        }

        func answer(to id: JSONRPCID) -> JSONRPCMessage? { lock.withLock { answers[id] } }

        func wait(for id: JSONRPCID) async -> JSONRPCMessage {
            await withCheckedContinuation { continuation in
                let answered: JSONRPCMessage? = lock.withLock {
                    if let answer = answers[id] { return answer }
                    waiters[id, default: []].append(continuation)
                    return nil
                }
                if let answered { continuation.resume(returning: answered) }
            }
        }
    }

    /// What the agent does in a turn: given the prompt's id and the client's answers so
    /// far, the messages to send when the prompt comes and when each answer comes.
    struct Script: Sendable {
        var onPrompt: @Sendable (JSONRPCID) throws -> [JSONRPCMessage]
        var onAnswer: @Sendable (JSONRPCID, JSONRPCMessage, JSONRPCID) throws -> [JSONRPCMessage] = { _, _, _ in [] }
        var onCancel: @Sendable (JSONRPCID) throws -> [JSONRPCMessage] = { _ in [] }
        /// Given `session/close`'s id, what to send, its answer included.
        var onClose: @Sendable (JSONRPCID) throws -> [JSONRPCMessage] = { [.response(id: $0, result: .object([:]))] }
    }

    /// Plays the agent on `agent`: answers the handshake and a new session (`s`), and
    /// runs `script` for the turn, recording every answer the client gives it.
    static func playAgent(on agent: LoopbackTransport, answers: Answers, script: Script) async throws {
        var prompt: JSONRPCID?
        for try await message in agent.makeInboundStream() {
            switch message {
            case .request(let request):
                switch request.method {
                case "initialize":
                    try agent.send(.response(id: request.id, result: try JSONValue(encoding: InitializeResponse())))
                case "session/new":
                    let session = NewSessionResponse(sessionId: "s")
                    try agent.send(.response(id: request.id, result: try JSONValue(encoding: session)))
                case "session/prompt":
                    prompt = request.id
                    for next in try script.onPrompt(request.id) { try agent.send(next) }
                case "session/close":
                    for next in try script.onClose(request.id) { try agent.send(next) }
                default: try agent.send(.response(id: request.id, result: .object([:])))
                }
            case .notification(let note) where note.method == "session/cancel":
                if let prompt { for next in try script.onCancel(prompt) { try agent.send(next) } }
            case .response(let response):
                answers.record(response.id, message)
                if let prompt { for next in try script.onAnswer(response.id, message, prompt) { try agent.send(next) } }
            case .errorResponse(let failure):
                guard let id = failure.id else { continue }
                answers.record(id, message)
                if let prompt { for next in try script.onAnswer(id, message, prompt) { try agent.send(next) } }
            default:
                continue
            }
        }
    }

    static func answer(_ prompt: JSONRPCID, _ stopReason: StopReason = .endTurn) throws -> JSONRPCMessage {
        .response(id: prompt, result: try JSONValue(encoding: PromptResponse(stopReason: stopReason)))
    }

    static let permission: JSONValue = .object([
        "sessionId": .string("s"),
        "toolCall": .object(["toolCallId": .string("t1"), "title": .string("Edit notes"), "kind": .string("edit")]),
        "options": .array([.object([
            "optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")
        ])])
    ])

    /// A connected client on `clientEnd`, its session `s` open, and — given `terminals` — a
    /// terminal manager for the agent's commands.
    static func client(
        _ clientEnd: LoopbackTransport, handlers: ACPClientHandlers, terminals: String? = nil
    ) async throws -> ACPAgentConnection {
        let client = ACPAgentConnection(transport: clientEnd, handlers: handlers)
        if let terminals { await client.setTerminalHandler(TerminalManager(cwd: terminals)) }
        await client.start()
        var capabilities = ClientCapabilities.headlessController
        capabilities.terminal = terminals != nil
        _ = try await client.initialize(capabilities: capabilities, clientInfo: .acpx)
        _ = try await client.newSession(NewSessionRequest(cwd: terminals ?? NSTemporaryDirectory()))
        return client
    }

    /// A permission question the agent asks just before answering, and that is still being
    /// asked at the answer, is answered `cancelled` there — and counted so, as acpx's
    /// `finishPermissionRequest` counts it.
    @Test(.timeLimit(.minutes(1)))
    func aQuestionOpenAtTheAnswerIsAnsweredCancelled() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let (prompts, promptCame) = AsyncStream<JSONRPCID>.makeStream()
        let script = Script { prompt in
            promptCame.yield(prompt)
            return [.request(id: "q1", method: "session/request_permission", params: Self.permission)]
        }
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: answers, script: script) }
        defer { agent.cancel() }
        let (asked, ask) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        var handlers = ACPClientHandlers.standard(permission: .approveAll)
        handlers.requestPermission = { _ in
            ask.yield()
            for await _ in released { break }
            return RequestPermissionResponse(outcome: .selected(optionId: "allow"))
        }
        let client = try await Self.client(clientEnd, handlers: handlers)

        let turn = Task { try await client.prompt(PromptRequest(sessionId: "s", prompt: [.text("hi")])) }
        var prompt: JSONRPCID?
        for await id in prompts {
            prompt = id
            break
        }
        // The agent answers while the question is being asked.
        for await _ in asked { break }
        try agentEnd.send(try Self.answer(try #require(prompt)))
        _ = try await turn.value
        release.finish()

        let answer = await answers.wait(for: "q1")
        guard case .response(let response) = answer else { throw CancellationError() }
        #expect(try #require(response.result).decoded(RequestPermissionResponse.self).outcome == .cancelled)
        let stats = await client.permissionStats(for: "s")
        #expect(stats.requested == 1 && stats.cancelled == 1 && stats.approved == 0)
        await client.close()
    }

    /// A write the agent asks for just before answering, served only once the answer is
    /// read, is answered `Request cancelled` without being served — acpx finds its owner
    /// ended — and is neither counted nor written.
    @Test(.timeLimit(.minutes(1)))
    func anOwnedRequestServedOnlyAfterTheAnswerIsNotServed() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let root = try ChildSpawnTests.workspace()
        let write: JSONValue = .object([
            "sessionId": .string("s"), "path": .string(root + "/out.txt"), "content": .string("x")
        ])
        let script = Script { prompt in
            [.request(id: "w1", method: "fs/write_text_file", params: write), try Self.answer(prompt)]
        }
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: answers, script: script) }
        defer { agent.cancel() }
        let asked = Flag()
        var handlers = ACPClientHandlers.standard(permission: .approveAll)
        handlers.authorizeWrite = { _ in asked.set() }
        let client = try await Self.client(clientEnd, handlers: handlers)
        let (answerRead, answered) = AsyncStream<Void>.makeStream()
        await client.setAfterPromptAnswer { answered.finish() }
        await client.setBeforeServingRequest { for await _ in answerRead { break } }

        _ = try await client.prompt(PromptRequest(sessionId: "s", prompt: [.text("hi")]))

        let answer = await answers.wait(for: "w1")
        guard case .errorResponse(let failure) = answer else { throw CancellationError() }
        #expect(failure.error.code == -32800)
        #expect(!asked.isSet)
        #expect(await client.permissionStats(for: "s").requested == 0)
        #expect(!FileManager.default.fileExists(atPath: root + "/out.txt"))
        await client.close()
    }

    /// A write whose permission is still being asked when the prompt's answer is read is
    /// stopped then — before the prompt's call resumes — as acpx aborts the owner at the
    /// answer and its handlers look again once asked. It is answered `Request cancelled`,
    /// and nothing is written. So too when a read of the same prompt was answered before:
    /// answering one request leaves the prompt's others to be stopped.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aWriteAskedAboutAcrossTheAnswerIsNotDone(afterARead: Bool) async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let root = try ChildSpawnTests.workspace()
        try "notes\n".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        let write: JSONValue = .object([
            "sessionId": .string("s"), "path": .string(root + "/out.txt"), "content": .string("x")
        ])
        let read: JSONValue = .object(["sessionId": .string("s"), "path": .string(root + "/notes.txt")])
        let (prompts, promptCame) = AsyncStream<JSONRPCID>.makeStream()
        let script = Script { prompt in
            promptCame.yield(prompt)
            let reading: [JSONRPCMessage] = afterARead
                ? [.request(id: "r1", method: "fs/read_text_file", params: read)] : []
            return [.request(id: "w1", method: "fs/write_text_file", params: write)] + reading
        }
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: answers, script: script) }
        defer { agent.cancel() }
        let (asking, askingStarted) = AsyncStream<Void>.makeStream()
        let (answerRead, answerReadNoted) = AsyncStream<Void>.makeStream()
        var handlers = ACPClientHandlers.standard(permission: .approveAll)
        handlers.authorizeWrite = { _ in
            askingStarted.yield()
            // Approved only once the prompt's answer has been read.
            for await _ in answerRead { break }
        }
        // The session's directory is the workspace, where the write is let through.
        let client = try await Self.client(clientEnd, handlers: handlers, terminals: root)
        await client.setWireObserver { line in
            if line.contains("\"stopReason\"") { answerReadNoted.finish() }
        }
        // The prompt's call resumes only once the write is answered.
        await client.setAfterPromptAnswer { _ = await answers.wait(for: "w1") }

        let turn = Task { try await client.prompt(PromptRequest(sessionId: "s", prompt: [.text("hi")])) }
        var prompt: JSONRPCID?
        for await id in prompts {
            prompt = id
            break
        }
        for await _ in asking { break }
        if afterARead, case .errorResponse(let refusal) = await answers.wait(for: "r1") {
            Issue.record("The read was refused: \(refusal.error.message)")
        }
        try agentEnd.send(try Self.answer(try #require(prompt)))
        _ = try await turn.value

        let answer = await answers.wait(for: "w1")
        guard case .errorResponse(let failure) = answer else { throw CancellationError() }
        #expect(failure.error.code == -32800)
        #expect(!FileManager.default.fileExists(atPath: root + "/out.txt"))
        await client.close()
    }

    /// Waiting for a command's exit is not the prompt's: a turn the agent answers while
    /// it waits ends at once, and the wait is answered when the command is done.
    @Test(.timeLimit(.minutes(1)))
    func aCommandsExitIsNotWaitedFor() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let create: JSONValue = .object([
            "sessionId": .string("s"), "command": .string("/bin/sleep"), "args": .array([.string("30")])
        ])
        var script = Script { _ in [.request(id: "c1", method: "terminal/create", params: create)] }
        script.onAnswer = { id, answer, prompt in
            guard id == "c1", case .response(let created) = answer, case .object(let fields)? = created.result,
                  let terminalId = fields["terminalId"] else { return [] }
            let wait: JSONValue = .object(["sessionId": .string("s"), "terminalId": terminalId])
            return [.request(id: "x1", method: "terminal/wait_for_exit", params: wait), try Self.answer(prompt)]
        }
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: answers, script: script) }
        defer { agent.cancel() }
        let client = try await Self.client(
            clientEnd, handlers: .standard(permission: .approveAll), terminals: try ChildSpawnTests.workspace())

        // Returns while `sleep 30` runs: a turn that waited for its exit would not.
        _ = try await client.prompt(PromptRequest(sessionId: "s", prompt: [.text("hi")]))

        #expect(answers.answer(to: "x1") == nil)
        await client.close()
    }

    /// A cancel ends what the prompt owns, not the rest of a command's requests: a wait
    /// for a command's exit asked before the cancel is still answered with its exit.
    @Test(.timeLimit(.minutes(1)))
    func aCancelLeavesACommandsWaitServed() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let create: JSONValue = .object([
            "sessionId": .string("s"), "command": .string("/bin/sleep"), "args": .array([.string("0.3")])
        ])
        var script = Script { _ in [.request(id: "c1", method: "terminal/create", params: create)] }
        script.onAnswer = { id, answer, _ in
            guard id == "c1", case .response(let created) = answer, case .object(let fields)? = created.result,
                  let terminalId = fields["terminalId"] else { return [] }
            let wait: JSONValue = .object(["sessionId": .string("s"), "terminalId": terminalId])
            return [.request(id: "x1", method: "terminal/wait_for_exit", params: wait)]
        }
        script.onCancel = { prompt in [try Self.answer(prompt, .cancelled)] }
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: answers, script: script) }
        defer { agent.cancel() }
        let client = try await Self.client(
            clientEnd, handlers: .standard(permission: .approveAll), terminals: try ChildSpawnTests.workspace())
        let (waiting, waitRead) = AsyncStream<Void>.makeStream()
        await client.setWireObserver { line in
            if line.contains("\"method\":\"terminal/wait_for_exit\"") { waitRead.yield() }
        }

        let turn = Task { try await client.prompt(PromptRequest(sessionId: "s", prompt: [.text("hi")])) }
        for await _ in waiting { break }
        try await client.cancel(sessionId: "s")
        #expect(try await turn.value.stopReason == .cancelled)

        let answer = await answers.wait(for: "x1")
        guard case .response(let exited) = answer else { throw CancellationError() }
        #expect(try #require(exited.result).decoded(WaitForTerminalExitResponse.self).exitCode == 0)
        await client.close()
    }
}

extension RequestOwnershipTests {
    /// A refusal that comes once the request's prompt ended it — the request was answered
    /// cancelled meanwhile, and what serves it cancelled — is not counted: acpx counts a
    /// refusal only while the request's owner is active (`runDelegatedOperation`).
    @Test(arguments: ["fs/write_text_file", "terminal/create"])
    func aRefusalAfterThePromptEndedItIsNotCounted(method: String) async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: Answers(), script: Script { _ in [] }) }
        defer { agent.cancel() }
        let root = try ChildSpawnTests.workspace()
        var handlers = ACPClientHandlers.standard(permission: .approveAll)
        handlers.authorizeWrite = { _ in throw FileSystemPermissionError.denied }
        handlers.authorizeTerminal = { _ in throw TerminalError.permissionDenied }
        let client = try await Self.client(clientEnd, handlers: handlers, terminals: root)
        let params: JSONValue = method == "fs/write_text_file"
            ? .object(["sessionId": .string("s"), "path": .string(root + "/out.txt"), "content": .string("x")])
            : .object(["sessionId": .string("s"), "command": .string("/bin/echo")])

        // Served the way a request of an ended prompt is still being served: cancelled.
        _ = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.handleIncomingRequest(method: method, params: params)
        }.value

        #expect(await client.permissionStats(for: "s").requested == 0)
        await client.close()
    }
}

/// Set once, read from anywhere.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
#endif
