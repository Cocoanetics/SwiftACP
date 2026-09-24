@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// The record acpxd writes for a session's turns is the one acpx writes for them (#85).
extension DaemonToolsTests {
    /// Two turns of `record-agent.py` leave the record acpx 0.19.1 left for the same two
    /// turns (`acpx-turn-record.json`): each message's members in the order acpx builds
    /// them, the tool results in the order their tools came, a thinking block's `null`
    /// signature, the usage by turn. What differs from run to run is left as a
    /// placeholder, and so are the event log's sequence and the last request's id, which
    /// SwiftACP does not keep as acpx does (#89, #64). How the agent is doing is left out
    /// (#87), and so is `agent_argv`: acpx ran the agent from its config.
    @Test(.enabled(if: mockPythonAvailable))
    func twoTurnsLeaveTheRecordAcpxLeaves() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let acpx = try Data(contentsOf: fixtures.appendingPathComponent("acpx-turn-record.json"))
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let agent = fixtures.appendingPathComponent("record-agent.py").path
            let id = try await daemon.newSession(agentCommand: "'\(python)' '\(agent)'", cwd: NSTemporaryDirectory())
            let blocks: [PromptBlock] = [.text("Look at this"), .resourceLink(uri: "file:///tmp/a.txt", name: "a.txt")]
            try await prompt(daemon, id, text: "", blocks: blocks, client: CallingClient())
            try await prompt(daemon, id, text: "Again", client: CallingClient())
            let written = try Data(contentsOf: ACPXPaths.sessionRecordPath(id))
            #expect(try Self.comparable(written) == Self.comparable(acpx))
        }
    }

    /// `record`'s text, with what differs from run to run as placeholders.
    private static func comparable(_ record: Data) throws -> String {
        var json = try #require(WireJSON(parsing: record))
        for key in [
            "agent_command", "cwd", "created_at", "last_used_at", "last_seq", "last_request_id",
            "agent_started_at", "last_prompt_at", "updated_at"
        ] {
            json = json.replacing(key, with: .text("<\(key)>"))
        }
        for key in [
            "agent_argv", "pid", "last_agent_exit_code", "last_agent_exit_signal", "last_agent_exit_at",
            "last_agent_disconnect_reason"
        ] {
            json = json.removing(key)
        }
        if let eventLog = json["event_log"] {
            json = json.replacing(
                "event_log",
                with: eventLog.replacing("active_path", with: .text("<active_path>"))
                    .replacing("last_write_at", with: .text("<last_write_at>")))
        }
        return json.stringified(indent: 2).replacingOccurrences(
            of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", with: "<id>",
            options: .regularExpression)
    }
}
