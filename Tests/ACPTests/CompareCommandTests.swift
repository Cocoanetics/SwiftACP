@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// `compare` reports each row's permissions as acpx 0.19.1 does (#97 review): the
/// requests and the refused ones, `permission_denied` when anything was refused, and an
/// error row when a question could not be asked — whatever refused it: the mode, a
/// `--permission-policy` rule, or `--non-interactive-permissions fail`.
struct CompareCommandTests {
    static func compare(_ flags: [String]) async throws -> (code: Int32, row: [String: Any]) {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/write-agent.py")
        let agent = "/usr/bin/env MOCK_TOOL_PERMISSION=1 '\(python)' '\(fixture.path)'"
        let (code, out) = await withIsolatedStore {
            let capture = Console.Capture()
            let code = Console.$capture.withValue(capture) {
                runCommandLine(["--format", "json"] + flags + ["compare", agent, "go"])
            }
            return (code, capture.out)
        }
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]])
        return (code, try #require(rows.first))
    }

    @Test(.enabled(if: mockPythonAvailable))
    func anApprovedPermissionCountsAsRequested() async throws {
        let (code, row) = try await Self.compare(["--approve-all"])
        #expect(code == ExitCodes.success)
        #expect(row["status"] as? String == "ok")
        #expect(row["permission_requests"] as? Int == 1)
        #expect(row["permission_denied"] as? Int == 0)
    }

    @Test(.enabled(if: mockPythonAvailable), arguments: [
        ["--deny-all"], ["--approve-all", "--permission-policy", #"{"autoDeny":["edit"]}"#]
    ])
    func aRefusalMakesTheRowPermissionDenied(flags: [String]) async throws {
        let (code, row) = try await Self.compare(flags)
        #expect(code == ExitCodes.permissionDenied)
        #expect(row["status"] as? String == "permission_denied")
        #expect(row["stop_reason"] as? String == "end_turn")
        #expect(row["permission_requests"] as? Int == 1)
        #expect(row["permission_denied"] as? Int == 1)
        #expect(row["final_message"] as? String == "outcome:reject")
    }

    /// acpx's `runOnce` fails the run on it: an error row that keeps what was said.
    @Test(.enabled(if: mockPythonAvailable))
    func anUnaskableQuestionIsAnErrorRow() async throws {
        let (code, row) = try await Self.compare(["--approve-reads", "--non-interactive-permissions", "fail"])
        #expect(code == ExitCodes.permissionDenied)
        #expect(row["status"] as? String == "permission_denied")
        #expect(row["stop_reason"] is NSNull)
        #expect(row["error"] as? String == "Permission prompt unavailable in non-interactive mode")
        #expect(row["final_message"] as? String == "outcome:cancelled")
        #expect(row["permission_denied"] as? Int == 1)
    }
}
