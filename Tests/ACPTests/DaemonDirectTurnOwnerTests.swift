@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A flow's direct turn runs outside its session's queue owner, as acpx's `sendSessionDirect`
/// takes only the session's turn (#225): a queued prompt sent meanwhile begins in the owner and
/// waits for the session within its `--timeout`, a cancel reaches that prompt and not the flow's
/// turn, and a control waits for the session. acpx's integration test "session turn ownership
/// preserves a live flow during CLI complete/timeout/cancel" (`test/integration.test.ts`).
extension DaemonToolsTests {
    /// A prompt queued while a flow's turn holds the session runs once that turn is over.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPromptQueuedBehindAFlowsTurnRunsOnceItIsOver() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.sessionForAFlow()
            let flow = try await Self.holdADirectTurn(daemon, id)
            let queued = await Self.queue(daemon, id, "queued behind")
            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "flow"))
            _ = try await flow.value
            _ = try await queued.value
            #expect(Self.prompts(of: id).contains("queued behind"))
            await daemon.releaseAll()
        }
    }

    /// A prompt queued behind a flow's turn waits for the session within its `--timeout`: past
    /// it, it fails with `TIMEOUT`, never sent, and the flow's turn goes on.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPromptQueuedBehindAFlowsTurnTimesOutUnsent() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.sessionForAFlow()
            let flow = try await Self.holdADirectTurn(daemon, id)
            let queued = await Self.queue(daemon, id, "timed out", timeoutMs: 200)
            await #expect(throws: TimeoutError.self) { _ = try await queued.value }
            #expect(!Self.prompts(of: id).contains("timed out"))
            #expect(await daemon.directTurns[id]?.first?.cancelAsked == false)
            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "flow"))
            _ = try await flow.value
            await daemon.releaseAll()
        }
    }

    /// A cancel reaches the prompt queued behind a flow's turn, as acpx's cancel reaches the
    /// queue owner alone: the prompt ends at once, cancelled and never sent, and the flow's turn
    /// goes on. With nothing queued, a cancel finds nothing.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCancelReachesTheQueuedPromptNotTheFlowsTurn() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.sessionForAFlow()
            let flow = try await Self.holdADirectTurn(daemon, id)
            #expect(try await daemon.cancelSession(sessionId: id) == false)
            let queued = await Self.queue(daemon, id, "cancelled")
            #expect(try await daemon.cancelSession(sessionId: id))
            #expect(try await queued.value == "")
            #expect(!Self.prompts(of: id).contains("cancelled"))
            #expect(await daemon.directTurns[id]?.first?.cancelAsked == false)
            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "flow"))
            _ = try await flow.value
            await daemon.releaseAll()
        }
    }

    /// A control sent while a flow's turn holds the session waits for the session, as acpx's
    /// direct control waits for its turn, within its `--timeout`; it never runs on the flow's
    /// agent. Closing the session still cancels the flow's turn.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlWaitsForAFlowsTurnAndACloseCancelsIt() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.sessionForAFlow()
            let flow = try await Self.holdADirectTurn(daemon, id)
            await #expect(throws: (any Error).self) {
                _ = try await daemon.setMode(sessionId: id, modeId: "auto", timeoutMs: 200)
            }
            #expect(SessionStore.loadRecord(id)?.acpx?.desiredModeId == nil)
            #expect(await daemon.directTurns[id]?.first?.cancelAsked == false)
            #expect(try await daemon.closeSession(sessionId: id))
            _ = try await flow.value
            await daemon.releaseAll()
        }
    }

    /// A control sent while a prompt queued behind a flow's turn waits for the session is that
    /// prompt's, as acpx's owner takes it on the prompt's ticket: the flow's turn, ending, leaves
    /// it be, and it runs on the prompt's agent once the prompt goes out (#229 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlForAPromptQueuedBehindAFlowsTurnIsThatPromptsOwn() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.sessionForAFlow()
            let flow = try await Self.holdADirectTurn(daemon, id)
            let queued = await Self.queue(daemon, id, "queued behind")
            let taken = HoldGate()
            await daemon.setControlTakenHook { _ in taken.open() }
            let control = Task { try await daemon.setMode(sessionId: id, modeId: "plan") }
            await taken.wait()
            await daemon.setControlTakenHook(nil)
            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "flow"))
            _ = try await flow.value
            #expect(try await control.value.resumed == false)
            _ = try await queued.value
            #expect(Self.prompts(of: id).contains("queued behind"))
            #expect(SessionStore.loadRecord(id)?.acpx?.desiredModeId == "plan")
            await daemon.releaseAll()
        }
    }

    /// A flow's direct turn waiting for the session behind another is begun already: a stop that
    /// names it ends it at once, nothing sent, and leaves the turn ahead of it running — each of
    /// the session's direct turns its own.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnStoppedAsItWaitsForTheSessionEndsAtOnce() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.sessionForAFlow()
            let flow = try await Self.holdADirectTurn(daemon, id)
            let waiting = HoldGate()
            await daemon.turnQueue.setOnQueued { _ in waiting.open() }
            let second = Task {
                try await daemon.runPrompt(
                    sessionId: id, text: "second", permissionMode: "approve-all", direct: true, turnToken: "second")
            }
            await waiting.wait()
            await daemon.turnQueue.setOnQueued(nil)
            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "second"))
            #expect(try await second.value == "")
            #expect(!Self.prompts(of: id).contains("second"))
            #expect(await daemon.directTurns[id]?.first?.cancelAsked == false)
            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "flow"))
            _ = try await flow.value
            await daemon.releaseAll()
        }
    }

    /// A close marks every turn of its session cancelled before it sends the first cancel: a
    /// flow's turn waiting for the session behind another ends then, nothing sent — it does not
    /// take the session and send its prompt while the cancel of the turn ahead goes out
    /// (#229 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCloseCancelsATurnWaitingBehindAnotherBeforeItsPromptGoesOut() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.sessionForAFlow()
            let flow = try await Self.holdADirectTurn(daemon, id)
            let waiting = HoldGate()
            await daemon.turnQueue.setOnQueued { _ in waiting.open() }
            let second = Task {
                try await daemon.runPrompt(
                    sessionId: id, text: "second", permissionMode: "approve-all", direct: true, turnToken: "second")
            }
            await waiting.wait()
            await daemon.turnQueue.setOnQueued(nil)
            // The close waits, once the flow's turn is cancelled, until the second turn is over:
            // left uncancelled, it would take the session meanwhile and send its prompt.
            await daemon.setCancelSent { _ in _ = try? await second.value }
            #expect(try await daemon.closeSession(sessionId: id))
            #expect(try await second.value == "")
            #expect(!Self.prompts(of: id).contains("second"))
            _ = try? await flow.value
            await daemon.releaseAll()
        }
    }

    /// A flow's direct turn that may not wait is refused at once while something holds the
    /// session, as a queued prompt that may not wait is: nothing sent, and the turn holding the
    /// session goes on (#229 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectTurnThatMayNotWaitIsRefusedWhileTheSessionIsHeld() async throws {
        try await withIsolatedStore {
            let (daemon, id) = try await Self.sessionForAFlow()
            let flow = try await Self.holdADirectTurn(daemon, id)
            let refused = await #expect(throws: DaemonError.self) {
                _ = try await daemon.runPrompt(
                    sessionId: id, text: "busy", wait: false, permissionMode: "approve-all", direct: true,
                    turnToken: "busy")
            }
            if case .sessionBusy? = refused {} else { Issue.record("refused with \(String(describing: refused))") }
            #expect(!Self.prompts(of: id).contains("busy"))
            #expect(await daemon.directTurns[id]?.count == 1)
            #expect(try await daemon.cancelSession(sessionId: id, turnToken: "flow"))
            _ = try await flow.value
            await daemon.releaseAll()
        }
    }

    /// A daemon, and a session made for a flow, its agent held for its first turn.
    private static func sessionForAFlow() async throws -> (ACPXDaemonBackend, String) {
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
        let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory(), holdAgent: true)
        return (daemon, id)
    }

    /// A flow's direct turn on `id`'s session, its prompt out and held by the agent until it is
    /// cancelled, under the token `flow`.
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

    /// A prompt queued on `id`'s session, once it waits for the session.
    private static func queue(
        _ daemon: ACPXDaemonBackend, _ id: String, _ text: String, timeoutMs: Int? = nil
    ) async -> Task<String, Error> {
        let waiting = HoldGate()
        await daemon.turnQueue.setOnQueued { _ in waiting.open() }
        let prompt = Task {
            try await daemon.runPrompt(
                sessionId: id, text: text, permissionMode: "approve-all",
                limits: timeoutMs.map { PromptLimits(timeoutMs: $0) })
        }
        await waiting.wait()
        await daemon.turnQueue.setOnQueued(nil)
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

extension ACPXDaemonBackend {
    func setCancelSent(_ hook: (@Sendable (_ recordId: String) async -> Void)?) {
        cancelSent = hook
    }
}
