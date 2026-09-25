@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A control sent while a session runs a prompt, as acpx 0.19.1's queue owner takes it
/// (#158): on the prompt's agent at once, not once the prompt is over. What it changes goes
/// into the prompt's record, saved at once. It waits for the prompt to go out, and fails if
/// the prompt ends before. Past its deadline once its request went out, it puts the
/// prompt's agent down.
extension DaemonToolsTests {
    /// A FIFO in `directory` for the agent to signal on, and its path.
    private func fifo(_ name: String, in directory: URL) throws -> URL {
        let path = directory.appendingPathComponent(name)
        guard mkfifo(path.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        return path
    }

    /// Wait for the agent to signal on `fifo` — bounded, so that a signal that never comes
    /// fails the test rather than hangs it.
    private func signalled(_ fifo: URL) async throws {
        try await withTimeout(milliseconds: 10_000) { try await Self.byteWritten(to: fifo) }
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlDuringAPromptRunsOnItsAgentAtOnce() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = try fifo("ready", in: directory)
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: "RETRY_AGENT_READY='\(ready.path)' ")
            try session.set("stall-prompt")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let prompt = Task {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            }
            try await signalled(ready)

            // Bounded, so that a control that waits for the prompt fails rather than hangs.
            let result = try await withTimeout(milliseconds: 10_000) {
                try await daemon.setMode(sessionId: session.id, modeId: "plan")
            }
            #expect(!result.resumed)
            #expect(await daemon.turnQueue.isBusy(session.id), "the prompt runs on")
            #expect(try #require(SessionStore.loadRecord(session.id)).acpx?.desiredModeId == "plan")

            _ = try await daemon.cancelSession(sessionId: session.id)
            _ = try? await prompt.value
            // The prompt's last save keeps it.
            #expect(try #require(SessionStore.loadRecord(session.id)).acpx?.desiredModeId == "plan")
            await daemon.releaseAll()
        }
    }

    /// A control waiting for a prompt that ends before it goes out fails as acpx's does.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlWaitingForAPromptThatNeverWentOutFails() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = try fifo("ready", in: directory)
        let pidFile = directory.appendingPathComponent("pid")
        try await withIsolatedStore {
            let session = try await retrySession(
                in: directory, environment: "RETRY_AGENT_READY='\(ready.path)' RETRY_AGENT_PID='\(pidFile.path)' ")
            // The prompt's agent never answers `session/new`, so the prompt never goes out.
            try session.set("hang-new")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let (taken, taking) = AsyncStream<Void>.makeStream()
            await daemon.setControlTakenHook { _ in taking.yield() }
            let prompt = Task {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            }
            try await signalled(ready)
            let control = Task { try await daemon.setMode(sessionId: session.id, modeId: "plan") }

            // Once the control waits on the prompt, the prompt's agent goes: the prompt ends
            // before it went out. Bounded, so that a control never taken fails rather than
            // hangs.
            try await withTimeout(milliseconds: 10_000) {
                var waiting = taken.makeAsyncIterator()
                _ = await waiting.next()
            }
            kill(try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8))), SIGKILL)
            await #expect(throws: PromptEndedBeforeControls.self) {
                _ = try await withTimeout(milliseconds: 10_000) { try await control.value }
            }
            _ = try? await prompt.value
            #expect(try #require(SessionStore.loadRecord(session.id)).acpx?.desiredModeId == nil)
            await daemon.releaseAll()
        }
    }

    /// A control the agent fails during a prompt is reported as the same control between
    /// turns is (#164): a rejection says which control and what was asked, any other agent
    /// error is its message alone, and an agent gone under it is acpx's disconnect.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: [
        ("RETRY_AGENT_SET_MODE_ERROR='{\"code\":-32602,\"message\":\"Invalid params\"}'",
         #"Agent rejected session/set_mode for mode "plan": Invalid params (ACP -32602). The adapter may not "#
            + "implement session/set_mode, or the requested value is not supported."),
        ("RETRY_AGENT_SET_MODE_ERROR='{\"code\":-32000,\"message\":\"boom\"}'", "boom"),
        ("RETRY_AGENT_SET_MODE_EXIT=1", "ACP agent disconnected during request (process_exit, exit=3, signal=null)")
    ])
    func aControlTheAgentFailsDuringAPromptIsReportedAsBetweenTurns(agent: String, reported: String) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = try fifo("ready", in: directory)
        try await withIsolatedStore {
            let session = try await retrySession(
                in: directory, environment: "RETRY_AGENT_READY='\(ready.path)' \(agent) ")
            try session.set("stall-prompt")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            func failure() async -> String? {
                do {
                    _ = try await withTimeout(milliseconds: 10_000) {
                        try await daemon.setMode(sessionId: session.id, modeId: "plan")
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            #expect(await failure() == reported, "between turns")
            let prompt = Task {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            }
            try await signalled(ready)
            #expect(await failure() == reported, "during the prompt")
            _ = try? await daemon.cancelSession(sessionId: session.id)
            _ = try? await prompt.value
            await daemon.releaseAll()
        }
    }

    /// A prompt a fresh launch takes over, its held agent having dropped the session, runs
    /// the turn's controls on the fresh launch: one sent as the turn moves over waits for
    /// the retry's prompt to go out, then runs on its agent (Codex review on #174).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlWhileAPromptMovesToAFreshLaunchWaitsForItsPrompt() async throws {
        try await withLoggedMock(loadMode: "ok", forgetAfterPrompts: 1) { command, methods in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")

            // As the retry connects, a control is taken on the turn's ticket.
            let (taken, taking) = AsyncStream<Void>.makeStream()
            let (controls, sending) = AsyncStream<Task<SessionControlResult, Error>>.makeStream()
            await daemon.setControlTakenHook { _ in taking.yield() }
            await daemon.setReconnected { _ in
                sending.yield(Task { try await daemon.setMode(sessionId: id, modeId: "plan") })
                var waiting = taken.makeAsyncIterator()
                _ = await waiting.next()
            }
            _ = try await withTimeout(milliseconds: 10_000) {
                try await daemon.runPrompt(sessionId: id, text: "second")
            }
            var sent = controls.makeAsyncIterator()
            let control = try #require(await sent.next())
            let result = try await withTimeout(milliseconds: 10_000) { try await control.value }
            #expect(!result.resumed)
            // Its mode went to the fresh launch after the retry's prompt, not to the agent
            // that dropped the session.
            let received = try methods()
            let retried = try #require(received.lastIndex(of: "session/prompt"))
            #expect(received.lastIndex(of: "session/set_mode").map { $0 > retried } == true, "\(received)")
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.desiredModeId == "plan")
            await daemon.releaseAll()
        }
    }

    /// Past its deadline once its request went out, a control puts the prompt's agent down,
    /// as acpx's control closes the prompt's client; the caller hears `TIMEOUT` at once.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlPastItsDeadlineDuringAPromptPutsThePromptsAgentDown() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = try fifo("ready", in: directory)
        let modeSent = try fifo("mode-sent", in: directory)
        let gate = directory.appendingPathComponent("gate")
        defer { FileManager.default.createFile(atPath: gate.path, contents: nil) }
        try await withIsolatedStore {
            let session = try await retrySession(
                in: directory, environment: "RETRY_AGENT_READY='\(ready.path)' "
                    + "RETRY_AGENT_SET_MODE_GATE='\(gate.path)' RETRY_AGENT_SET_MODE_SENT='\(modeSent.path)' ")
            try session.set("stall-prompt")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let prompt = Task {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            }
            try await signalled(ready)

            let control = Task { try await daemon.setMode(sessionId: session.id, modeId: "plan", timeoutMs: 300) }
            // The control's request reached the agent, which holds it past the deadline.
            try await signalled(modeSent)
            await #expect(throws: TimeoutError(milliseconds: 300)) {
                _ = try await withTimeout(milliseconds: 10_000) { try await control.value }
            }
            // The prompt ends on its agent's end, not by running on.
            let promptEnded = await Task {
                try await withTimeout(milliseconds: 10_000) { try await prompt.value }
            }.result
            guard case .failure(let error) = promptEnded else { throw CancellationError() }
            #expect(!(error is TimeoutError), "\(error)")
            #expect(await daemon.heldConnection(session.id) == nil)
            await daemon.releaseAll()
        }
    }
}

extension ACPXDaemonBackend {
    func setControlTakenHook(_ hook: (@Sendable (_ recordId: String) async -> Void)?) {
        controlTakenDuringPrompt = hook
    }
}
