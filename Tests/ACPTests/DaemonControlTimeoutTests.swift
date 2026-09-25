@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A control runs within the caller's `--timeout`, as acpx 0.19.1's do (#143): a direct
/// one — no owner holds the session — has each step bounded by it, an owned one all of it
/// by one deadline, at which its agent is let go. Either way, its wait for the session is
/// bounded too, and it fails as `TIMEOUT`.
extension DaemonToolsTests {
    /// A retry-agent session whose agent answers `session/set_mode` only after `delay`.
    private func slowModeSession(in directory: URL, delay: Int) async throws -> RetrySession {
        let sent = directory.appendingPathComponent("mode-sent")
        let session = try await retrySession(
            in: directory, environment: "RETRY_AGENT_DELAY_MS=\(delay) RETRY_AGENT_MODE_SENT='\(sent.path)' ")
        try session.set("slow-set-mode")
        return session
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDirectControlPastItsTimeoutFailsAndLetsItsAgentGo() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await slowModeSession(in: directory, delay: 5_000)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await #expect(throws: TimeoutError(milliseconds: 300)) {
                _ = try await daemon.setMode(sessionId: session.id, modeId: "plan", timeoutMs: 300)
            }
            #expect(await daemon.heldConnection(session.id) == nil)
            #expect(await daemon.sessionStatus(sessionId: session.id).live == false)
            #expect(try #require(SessionStore.loadRecord(session.id)).acpx?.desiredModeId == nil)
            await daemon.releaseAll()
        }
    }

    /// Past its deadline, an owned control's agent is let go under it, as acpx's owner
    /// closes its client — the owner still holding the session.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anOwnedControlPastItsDeadlineLetsTheAgentGo() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await slowModeSession(in: directory, delay: 5_000)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            #expect(await daemon.heldConnection(session.id) != nil)
            await #expect(throws: TimeoutError(milliseconds: 300)) {
                _ = try await daemon.setMode(sessionId: session.id, modeId: "plan", timeoutMs: 300)
            }
            #expect(await daemon.heldConnection(session.id) == nil)
            let status = await daemon.sessionStatus(sessionId: session.id)
            #expect(status.live && status.pid == nil)
            #expect(try #require(SessionStore.loadRecord(session.id)).pid == nil)
            await daemon.releaseAll()
        }
    }

    /// A control that cannot have the session within its timeout fails as `TIMEOUT`,
    /// having held nothing: the control holding the session goes on undisturbed.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlThatWaitsPastItsTimeoutHoldsNothing() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sent = directory.appendingPathComponent("mode-sent")
        guard mkfifo(sent.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        try await withIsolatedStore {
            let session = try await retrySession(
                in: directory, environment: "RETRY_AGENT_DELAY_MS=1000 RETRY_AGENT_MODE_SENT='\(sent.path)' ")
            try session.set("slow-set-mode")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = session.id
            async let holding = daemon.setMode(sessionId: id, modeId: "plan")
            try await Self.byteWritten(to: sent)
            await #expect(throws: TimeoutError(milliseconds: 200)) {
                _ = try await daemon.setMode(sessionId: id, modeId: "code", timeoutMs: 200)
            }
            _ = try await holding
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.desiredModeId == "plan")
            await daemon.releaseAll()
        }
    }

    @Test func aControlTimeoutPastATimersRangeIsRefused() async throws {
        #expect(try ACPXDaemonBackend.controlTimeout(0) == nil)
        #expect(try ACPXDaemonBackend.controlTimeout(-5) == nil)
        #expect(try ACPXDaemonBackend.controlTimeout(300) == 300)
        #expect(throws: DaemonError.self) {
            _ = try ACPXDaemonBackend.controlTimeout(JavaScriptNumber.maxTimerDelayMs + 1)
        }
    }

    /// The CLI reports the daemon's timeout as acpx does: `TIMEOUT`, exit 3, with its hint.
    @Test func theDaemonsTimeoutIsTheCLIsTimeoutError() async throws {
        await #expect(throws: TimeoutError(milliseconds: 300)) {
            try await DaemonClient.timingOut(after: 300) {
                throw DaemonClient.DaemonControlFailure(message: "Timed out after 300ms")
            }
        }
        await #expect(throws: DaemonClient.DaemonControlFailure.self) {
            try await DaemonClient.timingOut(after: 300) {
                throw DaemonClient.DaemonControlFailure(message: "Timed out after 500ms")
            }
        }
    }
}
