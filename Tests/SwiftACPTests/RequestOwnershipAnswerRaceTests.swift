#if os(macOS) || os(Linux)
@testable import SwiftACP
import Foundation
import JSONFoundation
import JSONRPCPeer
import Testing

// What a request its prompt owns comes to when the prompt's answer is read while it is
// taken up, asked about, or answered: the answer that goes back decides what counts and
// what is reported (#130). Split from `RequestOwnershipTests.swift` to keep each file
// inside the length limit.
extension RequestOwnershipTests {
    /// A question its handler decided, whose prompt's answer is read before that decision
    /// goes back, is answered `cancelled` — and counted once, as that: acpx's
    /// `finishPermissionRequest` counts the answer it returns.
    @Test(.timeLimit(.minutes(1)))
    func aQuestionDecidedAsItsPromptEndsCountsOnce() async throws {
        let served = try await Self.servedAcrossTheAnswer(
            "session/request_permission", Self.permission, handlers: .standard(permission: .approveAll))
        let stats = served.stats
        guard case .response(let response) = served.answer else { throw CancellationError() }
        #expect(try #require(response.result).decoded(RequestPermissionResponse.self).outcome == .cancelled)
        #expect(stats.requested == 1 && stats.cancelled == 1 && stats.approved == 0, "\(stats)")
    }

    /// A refusal whose answer has not gone back when its prompt's answer is read is
    /// answered `Request cancelled` then, and not counted — nor noted as a confirmation
    /// nobody could give: acpx counts a refusal as it answers with it, while its owner is
    /// active (`runDelegatedOperation`).
    @Test(.timeLimit(.minutes(1)), arguments: ["fs/write_text_file", "terminal/create"])
    func aRefusalOvertakenByItsPromptsAnswerIsNotCounted(method: String) async throws {
        let root = try ChildSpawnTests.workspace()
        var handlers = ACPClientHandlers.standard(permission: .approveAll)
        handlers.authorizeWrite = { _ in throw FileSystemPermissionError.promptUnavailable }
        handlers.authorizeTerminal = { _ in throw TerminalError.permissionDenied }
        let params: JSONValue = method == "fs/write_text_file"
            ? .object(["sessionId": .string("s"), "path": .string(root + "/out.txt"), "content": .string("x")])
            : .object(["sessionId": .string("s"), "command": .string("/bin/echo")])
        let served = try await Self.servedAcrossTheAnswer(method, params, handlers: handlers, terminals: root)
        let stats = served.stats
        guard case .errorResponse(let failure) = served.answer else { throw CancellationError() }
        #expect(failure.error.code == -32800)
        #expect(stats.requested == 0 && !stats.promptUnavailable, "\(stats)")
        #expect(!FileManager.default.fileExists(atPath: root + "/out.txt"))
    }

    /// A question its handler escalated reports the escalation with its answer — and not
    /// at all when its prompt's answer overtakes that answer: acpx reports what it answers,
    /// while the question's owner is active.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func anEscalationIsReportedOnlyWithTheAnswerItExplains(overtaken: Bool) async throws {
        var handlers = ACPClientHandlers.standard(permission: .approveAll)
        handlers.requestPermission = { request in
            let escalation = PermissionEscalation(request, matchedRule: nil, timestamp: "t")
            return RequestPermissionResponse(outcome: .selected(optionId: "allow"))
                .addingACPXMetadata(["permissionEscalation": try JSONValue(encoding: escalation)])
        }
        let served = try await Self.servedAcrossTheAnswer(
            "session/request_permission", Self.permission, handlers: handlers, overtaken: overtaken)
        guard case .response(let response) = served.answer else { throw CancellationError() }
        let outcome = try #require(response.result).decoded(RequestPermissionResponse.self).outcome
        #expect(outcome == (overtaken ? .cancelled : .selected(optionId: "allow")))
        #expect(served.operations.compactMap(\.escalation).count == (overtaken ? 0 : 1), "\(served.operations)")
    }

    /// A question taken up for its prompt just as the prompt's answer is read — after
    /// the prompt was looked at, before what serves the question started — is answered
    /// `cancelled` without its handler being asked, and not counted: acpx answers so a
    /// request whose owner is no longer active (`handlePermissionRequest`).
    @Test(.timeLimit(.minutes(1)))
    func aQuestionWhosePromptEndsAsItIsTakenUpIsNotAsked() async throws {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let (prompts, promptCame) = AsyncStream<JSONRPCID>.makeStream()
        let script = Script { prompt in
            promptCame.yield(prompt)
            return [.request(id: "q1", method: "session/request_permission", params: Self.permission)]
        }
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: answers, script: script) }
        defer { agent.cancel() }
        let asked = Flag()
        var handlers = ACPClientHandlers.standard(permission: .approveAll)
        handlers.requestPermission = { _ in
            asked.set()
            return RequestPermissionResponse(outcome: .selected(optionId: "allow"))
        }
        let client = try await Self.client(clientEnd, handlers: handlers)
        let (claimed, claimNoted) = AsyncStream<Void>.makeStream()
        let (answerRead, answerReadNoted) = AsyncStream<Void>.makeStream()
        await client.setWireObserver { line in
            if line.contains("\"stopReason\"") { answerReadNoted.finish() }
        }
        // Taken up for its prompt, then held until the prompt's answer has been read.
        await client.setAfterClaimingOwnedRequest {
            claimNoted.yield()
            for await _ in answerRead { break }
        }
        await client.setAfterPromptAnswer { _ = await answers.wait(for: "q1") }

        let turn = Task { try await client.prompt(PromptRequest(sessionId: "s", prompt: [.text("hi")])) }
        var prompt: JSONRPCID?
        for await id in prompts {
            prompt = id
            break
        }
        for await _ in claimed { break }
        try agentEnd.send(try Self.answer(try #require(prompt)))
        _ = try await turn.value

        guard case .response(let response) = await answers.wait(for: "q1") else { throw CancellationError() }
        #expect(try #require(response.result).decoded(RequestPermissionResponse.self).outcome == .cancelled)
        #expect(!asked.isSet)
        #expect(await client.permissionStats(for: "s").requested == 0)
        await client.close()
    }

    /// Two alike requests keep their own owners however their handlers start (#138): the
    /// first, read between turns, has none; the second, read during the next prompt, has
    /// that prompt. The first's handler is held until the prompt's answer has been read, so
    /// it starts last. It is then served, as acpx serves it the moment it is read. Claimed by
    /// method and params, it took the second's prompt, now answered, and was cancelled for it.
    @Test(.timeLimit(.minutes(1)))
    func alikeRequestsKeepTheirOwnOwners() async throws {
        let root = try ChildSpawnTests.workspace()
        let file = root + "/notes.txt"
        try "notes".write(toFile: file, atomically: true, encoding: .utf8)
        let read: JSONValue = .object(["sessionId": .string("s"), "path": .string(file)])
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let (prompts, promptCame) = AsyncStream<JSONRPCID>.makeStream()
        let script = Script { prompt in
            promptCame.yield(prompt)
            return [.request(id: "r2", method: "fs/read_text_file", params: read)]
        }
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: answers, script: script) }
        defer { agent.cancel() }
        // The session in `root`, where the file is to be read.
        let client = try await Self.client(clientEnd, handlers: .standard(permission: .approveAll), terminals: root)
        // The first request's handler is held, once it has been read, until the prompt's
        // answer has been read.
        let (held, noteHeld) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let holding = Flag()
        await client.setBeforeServingRequest {
            guard !holding.isSet else { return }
            holding.set()
            noteHeld.yield()
            for await _ in released { break }
        }
        let (answerRead, noteAnswerRead) = AsyncStream<Void>.makeStream()
        await client.setAfterPromptAnswer { noteAnswerRead.yield() }

        try agentEnd.send(.request(id: "r1", method: "fs/read_text_file", params: read))
        for await _ in held { break }
        let turn = Task { try await client.prompt(PromptRequest(sessionId: "s", prompt: [.text("hi")])) }
        var promptIds = prompts.makeAsyncIterator()
        let prompt = try #require(await promptIds.next())
        let secondAnswer = await answers.wait(for: "r2")
        try agentEnd.send(try Self.answer(prompt))
        for await _ in answerRead { break }
        release.finish()
        let firstAnswer = await answers.wait(for: "r1")
        _ = try await turn.value

        for (id, answer) in [("r1", firstAnswer), ("r2", secondAnswer)] {
            guard case .response(let served) = answer else {
                Issue.record("\(id) was not served: \(answer)")
                continue
            }
            #expect(try #require(served.result).decoded(ReadTextFileResponse.self).content == "notes", "\(id)")
        }
        await client.close()
    }

    /// Serve the agent's `method` request for its prompt and answer the prompt. Overtaken,
    /// the request's answer is held until the prompt's answer has been read, and the
    /// prompt's call until that request is answered; otherwise the prompt is answered once
    /// the request is. Returns what the agent was told, the turn's permission stats, and
    /// the client operations reported meanwhile.
    private static func servedAcrossTheAnswer(
        _ method: String, _ params: JSONValue, handlers: ACPClientHandlers, terminals: String? = nil,
        overtaken: Bool = true
    ) async throws -> Served {
        let (clientEnd, agentEnd) = LoopbackTransport.pair()
        let answers = Answers()
        let (prompts, promptCame) = AsyncStream<JSONRPCID>.makeStream()
        let script = Script { prompt in
            promptCame.yield(prompt)
            return [.request(id: "r1", method: method, params: params)]
        }
        let agent = Task { try await Self.playAgent(on: agentEnd, answers: answers, script: script) }
        defer { agent.cancel() }
        let client = try await Self.client(clientEnd, handlers: handlers, terminals: terminals)
        let (subscription, events) = await client.makeEventSubscription()
        let reported = Task {
            var operations: [ClientOperation] = []
            for await event in events {
                if case .clientOperation(let operation) = event { operations.append(operation) }
            }
            return operations
        }
        let (served, servedNoted) = AsyncStream<Void>.makeStream()
        let (answerRead, answerReadNoted) = AsyncStream<Void>.makeStream()
        if overtaken {
            await client.setWireObserver { line in
                if line.contains("\"stopReason\"") { answerReadNoted.finish() }
            }
            await client.setAfterServingOwnedRequest {
                servedNoted.yield()
                for await _ in answerRead { break }
            }
            await client.setAfterPromptAnswer { _ = await answers.wait(for: "r1") }
        }

        let turn = Task { try await client.prompt(PromptRequest(sessionId: "s", prompt: [.text("hi")])) }
        var prompt: JSONRPCID?
        for await id in prompts {
            prompt = id
            break
        }
        if overtaken {
            for await _ in served { break }
        } else {
            _ = await answers.wait(for: "r1")
        }
        try agentEnd.send(try Self.answer(try #require(prompt)))
        _ = try await turn.value

        let answer = await answers.wait(for: "r1")
        let stats = await client.permissionStats(for: "s")
        await client.endSubscription(subscription)
        let operations = await reported.value
        await client.close()
        return Served(answer: answer, stats: stats, operations: operations)
    }

    /// What the agent was told, the turn's permission stats, and the client operations
    /// reported meanwhile.
    private struct Served {
        var answer: JSONRPCMessage
        var stats: PermissionStats
        var operations: [ClientOperation]
    }
}

extension ACPAgentConnection {
    func setAfterServingOwnedRequest(_ hook: (@Sendable () async -> Void)?) {
        afterServingOwnedRequest = hook
    }

    func setAfterClaimingOwnedRequest(_ hook: (@Sendable () async -> Void)?) {
        afterClaimingOwnedRequest = hook
    }
}
#endif
