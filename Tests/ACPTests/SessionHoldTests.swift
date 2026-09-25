@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// Whether acpxd holds a session, as the prompt banner and `status` report it (#110) —
/// where acpx reports the health of the session's queue owner (`probeQueueOwnerHealth`).
extension DaemonToolsTests {
    /// The daemon holds a session once a turn has connected its agent — with that
    /// agent's pid — and no longer once the session is closed. Asked over MCP, as the CLI
    /// asks it. The turn's agent cannot take the session back, so the record goes on
    /// under the agent's new session id: it is the record the daemon holds.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theDaemonSaysWhetherItHoldsASession() async throws {
        let command = "/usr/bin/env MOCK_SESSION_ID_PER_PROCESS=1 " + (try #require(mockCommand()))
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await backend.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let proxy = MCPServerProxy(config: .stdioHandles(server: ACPXDaemon(backend: backend)))
            try await proxy.connect()

            let before = await DaemonClient.sessionHold(on: proxy, sessionId: id)
            _ = try await DaemonClient.runPrompt(
                on: proxy, stopReason: StopReasonBox(), sessionId: id,
                content: [.object(["type": .string("text"), "text": .string("hi")])], wait: true,
                permissionMode: "approve-all", nonInteractivePermissions: "deny")
            let during = await DaemonClient.sessionHold(on: proxy, sessionId: id)
            // The agent's pid, as the turn recorded it while the agent ran.
            let recordedPid = SessionStore.loadRecord(id)?.pid
            let replaced = SessionStore.loadRecord(id)?.acpSessionId != id
            _ = try await backend.closeSession(sessionId: id)
            let after = await DaemonClient.sessionHold(on: proxy, sessionId: id)
            await proxy.disconnect()

            #expect(before == .notHeld)
            #expect(replaced)
            #expect(recordedPid != nil)
            #expect(during == .held(pid: recordedPid))
            #expect(after == .notHeld)
        }
    }

    /// With no daemon, nothing holds a session. A daemon that holds the lock but does not
    /// answer is taken as acpx takes an owner whose socket cannot be reached; one from
    /// before it could say cannot.
    @Test func withoutADaemonThatAnswers() async throws {
        try await withIsolatedStore {
            let none = await DaemonClient.sessionHold(sessionId: "s")
            let lock = DaemonLock()
            #expect(try lock.acquire())
            // Nothing listens on port 1.
            lock.update(port: 1)
            let silent = await DaemonClient.sessionHold(sessionId: "s")
            lock.release()

            let legacy = MCPServerProxy(config: .stdioHandles(server: LegacyControlDaemon()))
            try await legacy.connect()
            let older = await DaemonClient.sessionHold(on: legacy, sessionId: "s")
            await legacy.disconnect()

            #expect(none == .notHeld)
            #expect(silent == .unreachable)
            #expect(older == .unknown)
        }
    }
}

/// The banner and `status` as acpx 0.19.1 prints them for each health of the session's
/// queue owner (`src/cli/output/render.ts`, `src/cli/status-command.ts`).
struct SessionHoldOutputTests {
    /// 2026-09-24T12:00:00Z.
    private static let now = Date(timeIntervalSince1970: 1_790_251_200)

    private static func record(exitCode: Int? = nil, signal: String? = nil) -> SessionRecord {
        var record = SessionRecord(
            acpxRecordId: "rec-1", acpSessionId: "sess-1", agentCommand: "codex-acp", cwd: "/work",
            createdAt: "2026-09-24T10:00:00.000Z", lastUsedAt: "2026-09-24T11:00:00.000Z")
        record.name = "alpha"
        record.agentStartedAt = "2026-09-24T10:58:57.250Z"
        record.lastPromptAt = "2026-09-24T11:00:00.000Z"
        record.lastAgentExitCode = exitCode.map(Nullable.value)
        record.lastAgentExitSignal = signal.map(Nullable.value)
        var acpx = SessionAcpxState()
        acpx.currentModelId = "gpt"
        record.acpx = acpx
        return record
    }

    private static func status(
        _ record: SessionRecord, _ hold: DaemonClient.SessionHold, format: String
    ) -> String {
        let capture = Console.Capture()
        Console.$capture.withValue(capture) {
            StatusCommand.printStatus(record, hold: hold, format: format, now: now)
        }
        return capture.out
    }

    @Test func theBannerSaysWhetherTheAgentIsHeld() {
        #expect(PromptCommand.connectionStatus(.held(pid: 7)) == "connected")
        #expect(PromptCommand.connectionStatus(.notHeld) == "starting")
        #expect(PromptCommand.connectionStatus(.unreachable) == "needs reconnect")
        #expect(PromptCommand.connectionStatus(.unknown) == "needs reconnect")
        #expect(PromptCommand.sessionBanner(Self.record(), cwd: "/work", status: "connected")
            == "[acpx] session alpha (rec-1) · /work · agent connected")
    }

    /// Held, the session is running, its agent's pid and uptime shown — `alive` in JSON.
    @Test func aHeldSessionIsRunning() {
        #expect(Self.status(Self.record(), .held(pid: 4242), format: "text") == """
            session: rec-1
            agent: codex-acp
            pid: 4242
            status: running
            model: gpt
            mode: -
            uptime: 01:01:02
            lastPromptTime: 2026-09-24T11:00:00.000Z

            """)
        #expect(Self.status(Self.record(), .held(pid: 4242), format: "json")
            == #"{"action":"status_snapshot","status":"alive","summary":"queue owner healthy","acpxRecordId":"rec-1","#
            + #""acpxSessionId":"sess-1","pid":4242,"model":"gpt","uptime":"01:01:02","#
            + #""lastPromptTime":"2026-09-24T11:00:00.000Z"}"# + "\n")
        #expect(Self.status(Self.record(), .held(pid: 4242), format: "quiet") == "running\n")
    }

    /// A daemon that holds the lock and does not answer leaves the session dead, with how
    /// its agent last exited; with nothing holding it, it is idle — or dead when its agent
    /// exited badly.
    @Test func anUnheldSessionIsIdleOrDead() {
        let exited = Self.record(exitCode: 1)
        #expect(Self.status(exited, .unreachable, format: "text").hasSuffix("""
            status: dead
            model: gpt
            mode: -
            uptime: -
            lastPromptTime: 2026-09-24T11:00:00.000Z
            exitCode: 1
            signal: -

            """))
        #expect(Self.status(Self.record(), .unreachable, format: "quiet") == "dead\n")
        #expect(Self.status(Self.record(), .notHeld, format: "quiet") == "idle\n")
        #expect(Self.status(Self.record(), .unknown, format: "quiet") == "idle\n")
        #expect(Self.status(exited, .notHeld, format: "quiet") == "dead\n")
        #expect(Self.status(Self.record(signal: "SIGKILL"), .notHeld, format: "json")
            == #"{"action":"status_snapshot","status":"dead","summary":"queue owner unavailable","#
            + #""acpxRecordId":"rec-1","acpxSessionId":"sess-1","model":"gpt","#
            + #""lastPromptTime":"2026-09-24T11:00:00.000Z","signal":"SIGKILL"}"# + "\n")
    }

    /// acpx's `formatUptime`: whole seconds since the start, as `HH:MM:SS` — the hours as
    /// many as there are, none before the start — and none without a start to count from.
    @Test func uptimeAsAcpxFormatsIt() {
        #expect(StatusCommand.uptime(since: "2026-09-24T10:58:57.250Z", now: Self.now) == "01:01:02")
        #expect(StatusCommand.uptime(since: "2026-09-20T08:00:00Z", now: Self.now) == "100:00:00")
        #expect(StatusCommand.uptime(since: "2026-09-24T12:00:05.000Z", now: Self.now) == "00:00:00")
        #expect(StatusCommand.uptime(since: nil, now: Self.now) == nil)
        #expect(StatusCommand.uptime(since: "yesterday", now: Self.now) == nil)
    }
}
