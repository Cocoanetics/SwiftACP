@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A session control reports whether it had to take the session back, as acpx's
/// `resumed` does (#78): `true` only when the agent was launched and `session/load`
/// got the session back — not for a session already held, nor for one a new session
/// replaced. Each case is what acpx 0.19.1 printed for the same mock agent: a control
/// on a session nothing holds runs directly and lets its agent go (#145), so the next
/// one takes the session back again; once a prompt's owner holds it, a control finds
/// it running.
extension DaemonToolsTests {
    @Test(.enabled(if: mockPythonAvailable))
    func aSessionTakenBackIsResumed() async throws {
        try await withLoggedMock(loadMode: "ok") { command, _ in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(try await daemon.setMode(sessionId: id, modeId: "auto").resumed)
            #expect(try await daemon.setMode(sessionId: id, modeId: "plan").resumed)
            // Held by the prompt's owner now: the next control finds it running.
            try await prompt(daemon, id, text: "hi", client: CallingClient())
            #expect(try await daemon.setMode(sessionId: id, modeId: "auto").resumed == false)
            await daemon.releaseAll()
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aReplacedSessionIsNotResumed() async throws {
        try await withLoggedMock(loadMode: "gone") { command, _ in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let result = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .setConfigOption(sessionId: id, configId: "effort", value: "high")
            #expect(result.resumed == false)
            // As the mock's reply reported them: none, the value only acknowledged.
            #expect(result.configOptions == nil)
        }
    }
}
