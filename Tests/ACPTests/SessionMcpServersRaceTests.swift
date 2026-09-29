@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A prompt that reaches its session before the owner a prompt ahead of it starts, checked against
/// that prompt's MCP config (Codex review on #293): acpx checks a CLI racing another to the session
/// against the owner that won it, not against none.
extension SessionMcpServersTests {
    /// Another config is refused at once, waiting or not; the same config waits its turn, and the
    /// owner has the config of the prompt that started it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPromptRacingTheOwnersFirstPromptIsCheckedAgainstIt() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.heldSession()
            let flow = try await Self.holdADirectTurn(daemon, id)
            let first = await Self.queue(daemon, id, "first", config: Self.file("/a.json", [Self.own]))
            let other = await Self.inLine(daemon, id, "other", config: Self.file("/b.json", [Self.other]))
            await #expect(throws: QueueMcpConfigConflict.self) {
                _ = try await daemon.runPrompt(
                    sessionId: id, text: "other, not waiting", wait: false, permissionMode: "approve-all",
                    callerConfig: Self.files([]))
            }
            let same = await Self.inLine(daemon, id, "same", config: Self.file("/a.json", [Self.own]))

            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "flow"))
            _ = try? await flow.value
            _ = try await first.value
            _ = try await same.value
            await #expect(throws: QueueMcpConfigConflict.self) { _ = try await other.value }
            let prompts = Self.prompts(of: id)
            #expect(prompts.contains("first") && prompts.contains("same"), "\(prompts)")
            #expect(!prompts.contains { $0.hasPrefix("other") }, "\(prompts)")
            #expect(await daemon.owners[id]?.client.config?.mcpConfigPath == "/a.json")
            #expect(await daemon.ownerConfigClaims[id] == nil)
            await daemon.releaseAll()
        }
    }

    /// The claim ends with the calls of the prompts that made it: once the prompt ahead is over
    /// without having begun, a prompt of another config is let in and starts the owner with its own.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aClaimEndsWithThePromptsThatMadeIt() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.heldSession()
            let flow = try await Self.holdADirectTurn(daemon, id)
            let first = await Self.queue(daemon, id, "first", config: Self.file("/a.json", [Self.own]), timeoutMs: 200)
            await #expect(throws: TimeoutError.self) { _ = try await first.value }
            #expect(await daemon.ownerConfigClaims[id] == nil)

            let next = await Self.queue(daemon, id, "next", config: Self.file("/b.json", [Self.other]))
            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "flow"))
            _ = try? await flow.value
            _ = try await next.value
            #expect(Self.prompts(of: id).contains("next"))
            #expect(await daemon.owners[id]?.client.config?.mcpConfigPath == "/b.json")
            await daemon.releaseAll()
        }
    }

    /// The claim outlives the prompt that made it while another that claimed it still waits: that
    /// one starts the owner, so a prompt of another config is still refused.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aClaimOutlivesThePromptThatMadeItWhileAnotherHoldsIt() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.heldSession()
            let flow = try await Self.holdADirectTurn(daemon, id)
            let first = await Self.queue(daemon, id, "first", config: Self.file("/a.json", [Self.own]))
            let second = await Self.inLine(daemon, id, "second", config: Self.file("/a.json", [Self.own]))
            // A cancel reaches the prompt begun, not the flow's turn: the second begins.
            #expect(try await daemon.cancelSession(sessionId: id))
            _ = try? await first.value
            await #expect(throws: QueueMcpConfigConflict.self) {
                _ = try await daemon.runPrompt(
                    sessionId: id, text: "other", wait: false, permissionMode: "approve-all",
                    callerConfig: Self.file("/b.json", [Self.other]))
            }

            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "flow"))
            _ = try? await flow.value
            _ = try await second.value
            let prompts = Self.prompts(of: id)
            #expect(prompts.contains("second") && !prompts.contains("other"), "\(prompts)")
            #expect(await daemon.owners[id]?.client.config?.mcpConfigPath == "/a.json")
            await daemon.releaseAll()
        }
    }

    /// A daemon, and a session on the mock agent — one that takes a session back — its agent held.
    private static func heldSession() async throws -> (ACPXDaemonBackend, String) {
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
        let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
        return (daemon, id)
    }

    /// A flow's direct turn on `id`'s session — which starts no owner — its prompt out and held by
    /// the agent until it is cancelled, under the token `flow`.
    private static func holdADirectTurn(_ daemon: ACPXDaemonBackend, _ id: String) async throws -> Task<String, Error> {
        let out = HoldGate()
        await daemon.setPromptGoingOut { _ in out.open() }
        let turn = Task {
            try await daemon.runPrompt(
                sessionId: id, text: "hold turn", permissionMode: "approve-all", direct: true, turnToken: "flow")
        }
        await out.wait()
        await daemon.setPromptGoingOut(nil)
        return turn
    }

    /// A prompt of `config` queued on `id`'s session, once it waits for the session held by another
    /// turn — or is over, refused before it waits.
    private static func queue(
        _ daemon: ACPXDaemonBackend, _ id: String, _ text: String, config: CallerConfig, timeoutMs: Int? = nil
    ) async -> Task<String, Error> {
        let waiting = HoldGate()
        await daemon.turnQueue.setOnQueued { _ in waiting.open() }
        let prompt = Task {
            defer { waiting.open() }
            return try await daemon.runPrompt(
                sessionId: id, text: text, permissionMode: "approve-all",
                limits: timeoutMs.map { PromptLimits(timeoutMs: $0) }, callerConfig: config)
        }
        await waiting.wait()
        await daemon.turnQueue.setOnQueued(nil)
        return prompt
    }

    /// A prompt of `config` on `id`'s session, once it waits in its owner's line behind the prompt
    /// begun — or is over, refused before it waits.
    private static func inLine(
        _ daemon: ACPXDaemonBackend, _ id: String, _ text: String, config: CallerConfig
    ) async -> Task<String, Error> {
        let waiting = HoldGate()
        await daemon.setPromptWaits { _ in waiting.open() }
        let prompt = Task {
            defer { waiting.open() }
            return try await daemon.runPrompt(
                sessionId: id, text: text, permissionMode: "approve-all", callerConfig: config)
        }
        await waiting.wait()
        await daemon.setPromptWaits(nil)
        return prompt
    }

    /// The prompts `id`'s session's record holds.
    private static func prompts(of id: String) -> [String] {
        (SessionStore.loadRecord(id)?.messages ?? []).compactMap { message in
            guard case .user(let user) = message else { return nil }
            return user.content.compactMap { content -> String? in
                if case .text(let text) = content { return text }
                return nil
            }.joined()
        }
    }
}
