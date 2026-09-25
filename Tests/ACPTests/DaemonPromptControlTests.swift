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
