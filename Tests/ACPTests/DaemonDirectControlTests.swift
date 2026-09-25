@testable import ACPXCore
@testable import acpxd
import Dispatch
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// A control on a session no queue owner holds runs as acpx 0.19.1 runs it then —
/// directly (`withConnectedSession`, #145): its agent connected for the control and
/// closed once it is done. One an owner holds goes to the owner's agent, which stays.
extension DaemonToolsTests {
    /// With no owner, the control's agent is let go: nothing holds the session after it,
    /// and the record says how the agent ended, with no pid.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlOnASessionNoOwnerHoldsClosesItsAgent() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.setMode(sessionId: session.id, modeId: "plan")
            #expect(await daemon.heldConnection(session.id) == nil)
            #expect(await daemon.sessionStatus(sessionId: session.id).live == false)
            let record = try #require(SessionStore.loadRecord(session.id))
            #expect(record.pid == nil)
            #expect(record.lastAgentDisconnectReason == "connection_close")
            await daemon.releaseAll()
        }
    }

    /// A control cut off by the daemon stopping once its reconnect started a new session
    /// leaves the record on that session all the same — acpx saves the record its control
    /// connected on the way out — and says how the agent it closed ended.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlCutOffByStoppingKeepsTheSessionItsReconnectStarted() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            // Each process of the mock has a session of its own: the control's can't load the
            // first process's, and starts a new one.
            let id = try await daemon.newSession(
                agentCommand: "/usr/bin/env MOCK_SESSION_ID_PER_PROCESS=1 " + command, cwd: NSTemporaryDirectory())
            let before = try #require(SessionStore.loadRecord(id)).acpSessionId
            await daemon.setReconnected { _ in await daemon.releaseAll() }
            do {
                _ = try await daemon.setMode(sessionId: id, modeId: "plan")
                Issue.record("the control went through a stopping daemon")
            } catch DaemonError.stopping {}
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.acpSessionId != before)
            #expect(record.pid == nil)
            #expect(record.lastAgentDisconnectReason == "connection_close")
        }
    }

    /// A turn cut off the same way says how the agent it closed ended: the record keeps
    /// no pid of it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTurnCutOffByStoppingSaysHowItsAgentEnded() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await daemon.setReconnected { _ in await daemon.releaseAll() }
            do {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: CallingClient())
                Issue.record("the turn went through a stopping daemon")
            } catch DaemonError.stopping {}
            let record = try #require(SessionStore.loadRecord(session.id))
            #expect(record.pid == nil)
            #expect(record.lastAgentDisconnectReason == "connection_close")
            #expect(session.prompts == 0)
        }
    }

    /// A session a prompt left its owner holding keeps its agent through a control.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlOnAnOwnedSessionKeepsItsAgent() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            let held = try #require(await daemon.heldConnection(session.id))
            _ = try await daemon.setConfigOption(sessionId: session.id, configId: "effort", value: "high")
            #expect(await daemon.heldConnection(session.id) === held)
            #expect(try #require(SessionStore.loadRecord(session.id)).pid != nil)
            await daemon.releaseAll()
        }
    }

    /// A close that comes while a control runs waits for it, as acpx's close drains its
    /// owner first: what the control writes comes before the close, not over it. One that
    /// runs past the grace has its agent closed under it — failing it — and the close
    /// still comes after what it writes.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: [300, 1_500])
    func aCloseWaitsForTheControlThatHoldsTheSession(controlMilliseconds: Int) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sent = directory.appendingPathComponent("mode-sent")
        guard mkfifo(sent.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        try await withIsolatedStore {
            let session = try await retrySession(
                in: directory,
                environment: "RETRY_AGENT_DELAY_MS=\(controlMilliseconds) RETRY_AGENT_MODE_SENT='\(sent.path)' ")
            try session.set("slow-set-mode")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = session.id
            async let control = daemon.setMode(sessionId: id, modeId: "plan")
            try await Self.byteWritten(to: sent)
            #expect(try await daemon.closeSession(sessionId: id))
            let controlled = try? await control
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.closed == true)
            if controlMilliseconds < ACPXDaemonBackend.closeGraceMilliseconds {
                #expect(controlled != nil)
                #expect(record.acpx?.desiredModeId == "plan")
            } else {
                #expect(controlled == nil)
            }
            await daemon.releaseAll()
        }
    }

    /// Return once a byte is written to the FIFO at `path`: opened for reading and
    /// writing, so that neither side waits for the other.
    static func byteWritten(to path: URL) async throws {
        let fd = open(path.path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        await withCheckedContinuation { (written: CheckedContinuation<Void, Never>) in
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
            reader.setEventHandler {
                var byte: UInt8 = 0
                guard read(fd, &byte, 1) > 0 else { return }
                reader.cancel()
                written.resume()
            }
            reader.setCancelHandler { close(fd) }
            reader.resume()
        }
    }

    /// A control that has to take the session back goes on with the block the reconnect
    /// built anew, places kept for members still unset — the order acpx wrote for
    /// `set-mode plan` on `retry-agent.py`, the desired mode where the clone holds it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlThatReconnectsWritesTheBlockAsAcpxBuildsIt() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.setMode(sessionId: session.id, modeId: "plan")
            let data = try Data(contentsOf: ACPXPaths.sessionRecordPath(session.id))
            guard case .object(let members)? = WireJSON(parsing: data)?["acpx"] else {
                Issue.record("no acpx block")
                return
            }
            let order = members.map { String(decoding: $0.key, as: UTF16.self) }
                .filter { $0 != "mcp_servers" && $0 != "client_capabilities" }
            #expect(order == [
                "desired_mode_id", "current_model_id", "available_models", "available_model_names", "model_control",
                "config_options"
            ])
            await daemon.releaseAll()
        }
    }
}

extension ACPXDaemonBackend {
    func setReconnected(_ hook: (@Sendable (_ recordId: String) async -> Void)?) {
        reconnected = hook
    }
}
