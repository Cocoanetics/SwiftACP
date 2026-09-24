@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A session's saved agent environment — acpx's `acpx.session_options.env` (#108): kept
/// through SwiftACP's writes with its names as they are, read as acpx reads it, and given
/// to the agent whenever the session starts it.
extension DaemonToolsTests {
    /// Rewrite the stored record's raw JSON.
    private func editRawRecord(_ id: String, _ edit: (inout [String: Any]) -> Void) throws {
        let url = ACPXPaths.sessionsDir.appendingPathComponent("\(id).json")
        var raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&raw)
        try JSONSerialization.data(withJSONObject: raw).write(to: url)
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aSessionsSavedEnvironmentIsKeptAndGivenToItsAgent() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            try editRawRecord(id) { raw in
                var acpx = raw["acpx"] as? [String: Any] ?? [:]
                acpx["session_options"] = ["env": [
                    "INITIAL_AGENT_MODE": "plan", "CustomMixedCase": "1", "lower_snake": "2", "camelCase": "3",
                    "NOT_A_STRING": 5
                ] as [String: Any]]
                raw["acpx"] = acpx
            }
            // Read as acpx reads it: the string entries, names as they are.
            let expected = ["INITIAL_AGENT_MODE": "plan", "CustomMixedCase": "1", "lower_snake": "2", "camelCase": "3"]
            #expect(SessionStore.loadRecord(id)?.acpx?.sessionOptions?.env == expected)

            // The agent the next turn starts has them.
            let reply = try await daemon.runPrompt(sessionId: id, text: "env CustomMixedCase")
            #expect(reply.contains("CustomMixedCase=1"))

            // And the record the turn wrote keeps them, names untouched.
            let url = ACPXPaths.sessionsDir.appendingPathComponent("\(id).json")
            let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let options = (raw["acpx"] as? [String: Any])?["session_options"] as? [String: Any]
            #expect(options?["env"] as? [String: String] == expected)
        }
    }
}
