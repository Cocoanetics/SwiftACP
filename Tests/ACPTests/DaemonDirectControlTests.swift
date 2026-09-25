@testable import ACPXCore
@testable import acpxd
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
