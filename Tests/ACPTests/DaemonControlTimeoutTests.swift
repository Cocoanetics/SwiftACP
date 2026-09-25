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
    /// A retry-agent session whose agent answers `session/set_mode` only after `delay`, or
    /// once there is a file at `gate`.
    private func slowModeSession(in directory: URL, delay: Int, gate: URL? = nil) async throws -> RetrySession {
        let sent = directory.appendingPathComponent("mode-sent")
        let session = try await retrySession(
            in: directory, environment: "RETRY_AGENT_DELAY_MS=\(delay) RETRY_AGENT_MODE_SENT='\(sent.path)' "
                + (gate.map { "RETRY_AGENT_MODE_GATE='\($0.path)' " } ?? ""))
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
                in: directory, environment: "RETRY_AGENT_DELAY_MS=3000 RETRY_AGENT_MODE_SENT='\(sent.path)' ")
            try session.set("slow-set-mode")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = session.id
            async let holding = daemon.setMode(sessionId: id, modeId: "plan")
            try await Self.byteWritten(to: sent)
            await #expect(throws: TimeoutError(milliseconds: 200)) {
                _ = try await daemon.setMode(sessionId: id, modeId: "code", timeoutMs: 200)
            }
            // It gave up waiting: the control it waited for still holds the session.
            #expect(await daemon.turnQueue.isBusy(id))
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

    /// A control over before its deadline keeps it from passing: nothing is put down.
    @Test func aDeadlineSettledInTimeNeverPasses() {
        let deadline = ControlDeadline(after: 60_000) { Issue.record("the deadline passed") }
        #expect(deadline.settle())
        #expect(!deadline.hasPassed)
    }

    /// A control answered once its deadline has passed, before what the deadline puts down
    /// is down, ends only once that is down, as acpx's control waits for its client's close
    /// (`await retirement`): its agent no longer held, and its pid not saved. Past that, the
    /// session's next turn would find the agent being put down, or have its own put down.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlAnsweredAsItsDeadlinePassesEndsOnceItsAgentIsDown() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let answer = directory.appendingPathComponent("answer")
        defer { FileManager.default.createFile(atPath: answer.path, contents: nil) }
        try await withIsolatedStore {
            let session = try await slowModeSession(in: directory, delay: 0, gate: answer)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            let (overdue, noteOverdue) = AsyncStream<Void>.makeStream()
            // As the deadline passes the agent answers, and the agent is put down only once
            // the control waits for that — or, should it not wait, once it has ended.
            await daemon.setDeadlineHooks(passed: { _ in
                FileManager.default.createFile(atPath: answer.path, contents: nil)
                for await _ in overdue { break }
            }, overdue: { _ in noteOverdue.yield() })
            await #expect(throws: TimeoutError(milliseconds: 300)) {
                _ = try await daemon.setMode(sessionId: session.id, modeId: "plan", timeoutMs: 300)
            }
            let held = await daemon.heldConnection(session.id)
            let pid = try #require(SessionStore.loadRecord(session.id)).pid
            noteOverdue.finish()
            #expect(held == nil)
            #expect(pid == nil)
            await daemon.releaseAll()
        }
    }

    /// A control whose answer comes only once its deadline has passed is too late, as
    /// acpx's deadline settles first: its settling says so, and the control times out.
    @Test(.timeLimit(.minutes(1)))
    func anAnswerAfterTheDeadlinePassedIsTooLate() async {
        let (passed, passing) = AsyncStream<Void>.makeStream()
        let deadline = ControlDeadline(after: 1) { passing.yield() }
        var putDown = passed.makeAsyncIterator()
        _ = await putDown.next()
        #expect(deadline.hasPassed)
        #expect(!deadline.settle())
    }
}

extension ACPXDaemonBackend {
    func setDeadlineHooks(
        passed: (@Sendable (_ recordId: String) async -> Void)?,
        overdue: (@Sendable (_ recordId: String) async -> Void)?
    ) {
        deadlinePassed = passed
        controlOverdue = overdue
    }
}
