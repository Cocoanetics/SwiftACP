@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// A daemon turn under acpx's `--timeout` and `--prompt-retries` (#106), as acpx 0.19.1's
/// queue owner runs one: each step of connecting, the turn's model and each attempt at
/// the prompt within the timeout, and a prompt that fails the way a passing fault does
/// sent again while the turn has had no effect. On `retry-agent.py`, whose session is
/// created on a working agent: what a later launch does is what its mode file then says.
extension DaemonToolsTests {
    /// A session on `retry-agent.py`, and the files that steer its later launches.
    struct RetrySession {
        let id: String
        let mode: URL
        let attempts: URL

        /// How many prompts the agent was sent since its mode was last set.
        var prompts: Int {
            ((try? String(contentsOf: attempts, encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        /// From its next launch on, the agent does what `mode` says.
        func set(_ mode: String) throws {
            try mode.write(to: self.mode, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: attempts)
        }
    }

    // MARK: - --timeout

    /// A prompt the agent does not answer in time fails the turn with `TIMEOUT`: the
    /// prompt is cancelled once the session's updates have gone quiet — the JSON stream
    /// shows `session/cancel` after it, and the report — and its agent let go.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPromptPastTheTimeoutIsCancelledAndItsAgentLetGo() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("stall-prompt")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let client = CallingClient()
            await #expect(throws: TimeoutError(milliseconds: 300)) {
                try await limitedPrompt(
                    daemon, session.id, limits: PromptLimits(timeoutMs: 300), streamWire: true, client: client)
            }
            let turn = Array(client.wireKinds.drop { $0 != "wire:outbound:session/prompt" })
            #expect(turn.first == "wire:outbound:session/prompt")
            #expect(turn.contains("wire:outbound:session/cancel"))
            #expect(turn.last == "failed:TIMEOUT")
            #expect(session.prompts == 1)
            #expect(await daemon.sessionStatus(sessionId: session.id).live == false)
            await daemon.releaseAll()
        }
    }

    /// An answer that comes past the deadline, while the session's updates go quiet,
    /// stands — as acpx takes it (`recoveredSessionResult`) — and the agent is kept.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anAnswerThatComesWhileTheUpdatesGoQuietStands() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: "RETRY_AGENT_DELAY_MS=1000 ")
            try session.set("slow-prompt")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let text = try await TurnReplyDrain.$current.withValue(
                ReplyDrain(idleMilliseconds: 1_500, timeoutMilliseconds: 5_000)
            ) {
                try await limitedPrompt(
                    daemon, session.id, limits: PromptLimits(timeoutMs: 300), client: CallingClient())
            }
            #expect(text == "hello")
            #expect(await daemon.sessionStatus(sessionId: session.id).live)
            await daemon.releaseAll()
        }
    }

    /// Each step of connecting goes within the timeout, as acpx's `connectAndLoadSession`
    /// bounds it: a step that runs over fails the turn before its prompt goes out.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: ["hang-init", "hang-new"])
    func aStepOfConnectingPastTheTimeoutFailsTheTurn(_ mode: String) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set(mode)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await #expect(throws: TimeoutError(milliseconds: 300)) {
                try await limitedPrompt(
                    daemon, session.id, limits: PromptLimits(timeoutMs: 300), client: CallingClient())
            }
            #expect(session.prompts == 0)
            #expect(await daemon.sessionStatus(sessionId: session.id).live == false)
            await daemon.releaseAll()
        }
    }

    /// So does putting the turn's `--model` on the session (`applyPromptModelIfAdvertised`).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theTurnsModelPastTheTimeoutFailsTheTurn() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("hang-model")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await #expect(throws: TimeoutError(milliseconds: 300)) {
                try await limitedPrompt(
                    daemon, session.id, limits: PromptLimits(timeoutMs: 300), model: "b", client: CallingClient())
            }
            #expect(session.prompts == 0)
            await daemon.releaseAll()
        }
    }

    // MARK: - --prompt-retries

    /// A prompt that fails the way a passing fault does is sent again, after acpx's
    /// pause. The failed attempt's error goes to the client where it came — before what
    /// the next attempt says — as acpx's formatter shows it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPromptThatFailsIsSentAgain() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("fail-once")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let client = CallingClient()
            let text = try await limitedPrompt(
                daemon, session.id, limits: PromptLimits(promptRetries: 1), client: client)
            #expect(text == "hello")
            #expect(session.prompts == 2)
            #expect(Self.errorsAndUpdates(client) == ["wire:inbound:error", "update:hello"])
            await daemon.releaseAll()
        }
    }

    /// Without `--prompt-retries` it is not.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPromptThatFailsIsNotSentAgainUnasked() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("fail-once")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await #expect(throws: JSONRPCErrorBody.self) {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: CallingClient())
            }
            #expect(session.prompts == 1)
            await daemon.releaseAll()
        }
    }

    /// A failure after an effect (an update), with one during the pause, or of a kind
    /// that does not pass (authentication) is not retried: what the client saw of it, in
    /// the order it came.
    struct NotRetried: Sendable, CustomTestStringConvertible {
        var mode: String
        var shown: [String]
        var testDescription: String { mode }
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: [
        NotRetried(mode: "fail-after-update", shown: ["update:partial ", "wire:inbound:error"]),
        NotRetried(mode: "fail-then-update", shown: ["wire:inbound:error", "update:late "]),
        NotRetried(mode: "fail-auth-once", shown: ["wire:inbound:error"])
    ])
    func aFailureThatIsNotAPassingFaultIsNotRetried(_ expected: NotRetried) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set(expected.mode)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let client = CallingClient()
            await #expect(throws: JSONRPCErrorBody.self) {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(promptRetries: 1), client: client)
            }
            #expect(session.prompts == 1)
            #expect(Self.errorsAndUpdates(client) == expected.shown)
            await daemon.releaseAll()
        }
    }

    /// A cancel during the pause before a retry ends the turn cancelled, the prompt not
    /// sent again — acpx's aborted pause (`preparePromptRetry`) — and with no answer to
    /// mark it done.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCancelDuringThePauseEndsTheTurnCancelled() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("fail-once")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = session.id
            await daemon.setRetryPaused { _ in _ = try? await daemon.cancelSession(sessionId: id) }
            let client = CallingClient()
            _ = try await limitedPrompt(daemon, id, limits: PromptLimits(promptRetries: 1), client: client)
            #expect(session.prompts == 1)
            let ended = try #require(client.logs.lazy.compactMap { try? $0.decoded(TurnEndedEvent.self) }.first)
            #expect(ended.stopReason == "cancelled")
            #expect(ended.unanswered == true)
            await daemon.releaseAll()
        }
    }

    /// So does a cancel of the prompt that then fails as a passing fault would: once
    /// cancelled, the turn is not sent again.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCancelledPromptThatFailsIsNotSentAgain() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("fail-on-cancel")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = session.id
            // Past the check that keeps an unsent prompt back: the cancel follows it out.
            await daemon.setPromptGoingOut { _ in _ = try? await daemon.cancelSession(sessionId: id) }
            let client = CallingClient()
            _ = try await limitedPrompt(daemon, id, limits: PromptLimits(promptRetries: 1), client: client)
            #expect(session.prompts == 1)
            let ended = try #require(client.logs.lazy.compactMap { try? $0.decoded(TurnEndedEvent.self) }.first)
            #expect(ended.stopReason == "cancelled")
            await daemon.releaseAll()
        }
    }

    /// acpx's queue owner refuses a negative retry count.
    @Test func aNegativeRetryCountIsRefused() async throws {
        let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
        await #expect(throws: DaemonError.self) {
            try await daemon.runPrompt(sessionId: "any", text: "hi", limits: PromptLimits(promptRetries: -1))
        }
    }

    // MARK: - Support

    /// A session on `retry-agent.py`, created on a working agent, with `environment` as
    /// `NAME=value ` pairs.
    private func retrySession(in directory: URL, environment: String = "") async throws -> RetrySession {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/retry-agent.py")
        let session = RetrySession(
            id: "", mode: directory.appendingPathComponent("mode"),
            attempts: directory.appendingPathComponent("attempts"))
        try session.set("ok")
        let command = "/usr/bin/env " + environment + "RETRY_AGENT_MODE_FILE='\(session.mode.path)' "
            + "RETRY_AGENT_ATTEMPTS='\(session.attempts.path)' '\(python)' '\(fixture.path)'"
        let created = try await SessionEngine.createSession(
            agentCommand: command, cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll,
            authCredentials: [:], authPolicy: "skip")
        return RetrySession(id: created.acpxRecordId, mode: session.mode, attempts: session.attempts)
    }

    /// Run one turn with `limits` as a calling client's request, answered on `client`.
    @discardableResult
    private func limitedPrompt(
        _ daemon: ACPXDaemonBackend, _ sessionId: String, limits: PromptLimits, model: String? = nil,
        streamWire: Bool = false, client: CallingClient
    ) async throws -> String {
        let session = Session(id: UUID())
        await session.setTransport(client)
        return try await session.work { _ in
            try await daemon.runPrompt(
                sessionId: sessionId, text: "hi", streamWire: streamWire, model: model, limits: limits)
        }
    }

    /// The agent's error responses and its reply chunks the client got, in order.
    private static func errorsAndUpdates(_ client: CallingClient) -> [String] {
        client.kinds.filter { $0 == "wire:inbound:error" || $0.hasPrefix("update:") }
    }
}

extension ACPXDaemonBackend {
    func setRetryPaused(_ hook: (@Sendable (_ recordId: String) async -> Void)?) {
        retryPaused = hook
    }
}

/// The CLI's end of a turn with no answer: nothing marks it done, as acpx's formatter
/// marks a turn done only at the prompt's answer on the wire.
struct UnansweredTurnEndTests {
    @Test func aTurnEndedWithoutAnAnswerIsNotMarkedDone() async throws {
        let out = OutputRendererTests.Capture()
        let renderer = OutputRenderer(
            options: RenderOptions(format: .text), out: out.write, err: { _ in }, color: false)
        let logs = PromptLogRenderer(renderer, stopReason: StopReasonBox())
        // Never connected: the handler only needs it to be called with.
        let proxy = MCPServerProxy(config: .stdioHandles(server: ACPXDaemon(backend: ACPXDaemonBackend())))
        let ended = try JSONValue(encoding: TurnEndedEvent(stopReason: "cancelled", unanswered: true))
        await logs.mcpServerProxy(proxy, didReceiveLog: LogMessage(level: .info, logger: "s", data: ended))
        renderer.finish(stopReason: .cancelled, answered: false)
        #expect(!out.text.contains("[done]"))
    }
}
