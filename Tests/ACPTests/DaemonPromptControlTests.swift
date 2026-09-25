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
            try await Self.byteWritten(to: ready)

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
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: "RETRY_AGENT_READY='\(ready.path)' ")
            // The prompt's agent never answers `session/new`: the prompt times out connecting.
            try session.set("hang-new")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let prompt = Task {
                try await limitedPrompt(
                    daemon, session.id, limits: PromptLimits(timeoutMs: 500), client: CallingClient())
            }
            try await Self.byteWritten(to: ready)

            // Bounded, so that a control left waiting fails rather than hangs.
            await #expect(throws: PromptEndedBeforeControls.self) {
                _ = try await withTimeout(milliseconds: 10_000) {
                    try await daemon.setMode(sessionId: session.id, modeId: "plan")
                }
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
            try await Self.byteWritten(to: ready)

            let control = Task { try await daemon.setMode(sessionId: session.id, modeId: "plan", timeoutMs: 300) }
            // The control's request reached the agent, which holds it past the deadline. Each
            // wait is bounded, so that a control that never goes out fails rather than hangs.
            try await withTimeout(milliseconds: 10_000) { try await Self.byteWritten(to: modeSent) }
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
