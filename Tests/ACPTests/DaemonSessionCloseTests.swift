@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// `sessions close` asks the agent the session's owner holds to close the session, when
/// it advertises it can (`sessionCapabilities.close`), as acpx 0.19.1's owner does once
/// drained (#160). No owner, or no such capability, and nothing is asked.
extension DaemonToolsTests {
    /// Close a session a prompt left owned; the session id the agent was asked to close, if any.
    private func closeAfterAPrompt(canClose: Bool, prompting: Bool = true) async throws -> String? {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let closed = directory.appendingPathComponent("closed")
        return try await withIsolatedStore {
            let session = try await retrySession(
                in: directory,
                environment: (canClose ? "RETRY_AGENT_CAN_CLOSE=1 " : "") + "RETRY_AGENT_CLOSED='\(closed.path)' ")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            if prompting {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            }
            #expect(try await daemon.closeSession(sessionId: session.id))
            #expect(try #require(SessionStore.loadRecord(session.id)).closed == true)
            await daemon.releaseAll()
            return try? String(contentsOf: closed, encoding: .utf8)
        }
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func closingAsksAnAgentThatCanCloseTheSession() async throws {
        #expect(try await closeAfterAPrompt(canClose: true) == "retry-session")
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func closingAsksNothingOfAnAgentThatCannot() async throws {
        #expect(try await closeAfterAPrompt(canClose: false) == nil)
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func closingASessionNoOwnerHoldsAsksNothing() async throws {
        #expect(try await closeAfterAPrompt(canClose: true, prompting: false) == nil)
    }
}
