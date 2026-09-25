@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A control the agent turns down is reported by the daemon as acpx's CLI reports it
/// (#164): a rejection says which control and what was asked, and any other agent error
/// is its message alone (`formatErrorMessage`).
extension DaemonToolsTests {
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: [
        (#"{"code":-32602,"message":"Invalid params"}"#,
         #"Agent rejected session/set_mode for mode "plan": Invalid params (ACP -32602). The adapter may not "#
            + "implement session/set_mode, or the requested value is not supported."),
        (#"{"code":-32000,"message":"boom"}"#, "boom")
    ])
    func aModeTheAgentTurnsDownIsReportedAsAcpxReportsIt(error: String, reported: String) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: "RETRY_AGENT_SET_MODE_ERROR='\(error)' ")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            do {
                _ = try await daemon.setMode(sessionId: session.id, modeId: "plan")
                Issue.record("the mode was set")
            } catch {
                #expect(error.localizedDescription == reported)
            }
            await daemon.releaseAll()
        }
    }
}
