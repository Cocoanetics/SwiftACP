import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// Negative identity regressions for #345 (part of #343): nothing Antigravity's adapter sends
/// today — the opaque flattened `name`, the display `title`, `kind`, `args`, `rawInput`, the
/// `initialize` agent name, or a split of the flattened name — yields an MCP server/tool
/// identity. The host is told identity is unavailable and must fail closed.
struct AntigravityMCPIdentityTests {
    private static let unavailable = MCPToolIdentityAvailability.unavailable(
        reason: AntigravityCompat.mcpIdentityBlocker)

    private static func permissionRequest(_ wire: String) throws -> RequestPermissionRequest {
        try JSONDecoder().decode(RequestPermissionRequest.self, from: Data(wire.utf8))
    }

    /// The sanitized #343 permission shape: flattened name, display title, kind, args and
    /// rawInput — from Antigravity or any other agent name, no identity.
    @Test func sanitizedAntigravityPermissionShapeHasNoIdentity() throws {
        let request = try Self.permissionRequest(#"""
            {"sessionId":"s","toolCall":{"toolCallId":"call-example",
            "name":"mcp_missioncontrol_view_issue",
            "args":{"number":277,"repo":"Cocoanetics/SwiftPorts"},
            "title":"Run mcp_missioncontrol_view_issue","kind":"other",
            "rawInput":{"number":277,"repo":"Cocoanetics/SwiftPorts"}},
            "options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}
            """#)
        #expect(request.toolCall.name == "mcp_missioncontrol_view_issue")
        for agentName in [AntigravityCompat.agentName, "missioncontrol", "some-other-acp", nil] {
            #expect(AntigravityCompat.mcpToolIdentity(of: request.toolCall, agentName: agentName)
                == Self.unavailable)
        }
    }

    /// A flattened name splits more than one way (`missioncontrol` + `view_issue`,
    /// `missioncontrol_view` + `issue`), so no split is taken — nor a title or kind that
    /// seem to agree with one of them.
    @Test func ambiguousFlattenedNameSplitsYieldNoIdentity() {
        for name in [
            "mcp_missioncontrol_view_issue", "mcp_mission_control_view_issue",
            "mcp__missioncontrol__view_issue", "missioncontrol.view_issue", "view_issue"
        ] {
            let update = ToolCallUpdate(
                toolCallId: "t", title: "missioncontrol: view_issue", kind: .read, name: name)
            let call = ToolCall(toolCallId: "t", title: "Run \(name)", kind: .fetch, name: name)
            #expect(AntigravityCompat.mcpToolIdentity(of: update, agentName: AntigravityCompat.agentName)
                == Self.unavailable)
            #expect(AntigravityCompat.mcpToolIdentity(of: call, agentName: AntigravityCompat.agentName)
                == Self.unavailable)
        }
    }

    /// An explicit-looking server/tool pair in `args`, `rawInput` or `title` is still only an
    /// adapter assertion with no provenance or binding to a configured server: no identity.
    @Test func explicitLookingPairInArgumentsOrTitleYieldsNoIdentity() {
        let pair = JSONValue.object(["server": .string("missioncontrol"), "tool": .string("view_issue")])
        let update = ToolCallUpdate(
            toolCallId: "t", title: "missioncontrol/view_issue", kind: .other,
            rawInput: pair, name: "view_issue", args: pair)
        #expect(AntigravityCompat.mcpToolIdentity(of: update, agentName: AntigravityCompat.agentName)
            == Self.unavailable)
    }

    /// A shell call's `rawInput.CommandLine` reaches the host byte for byte — the host's
    /// command allowlist reads it — and gives no identity either.
    @Test func commandLineRawInputStaysByteIdenticalAndGivesNoIdentity() throws {
        let commandLine = #"git status --porcelain  && echo "ok" | tr -d '\n'"#
        let request = try Self.permissionRequest(#"""
            {"sessionId":"s","toolCall":{"toolCallId":"call-shell","name":"run_command",
            "title":"Run shell command","kind":"execute",
            "args":{"CommandLine":"rm -rf /tmp/fake"},
            "rawInput":{"CommandLine":"git status --porcelain  && echo \"ok\" | tr -d '\\n'"}},
            "options":[{"optionId":"deny","name":"Deny","kind":"reject_once"}]}
            """#)
        #expect(request.toolCall.rawInput == .object(["CommandLine": .string(commandLine)]))
        #expect(AntigravityCompat.mcpToolIdentity(of: request.toolCall, agentName: AntigravityCompat.agentName)
            == Self.unavailable)

        // Re-encoded, the command line is still the same bytes.
        let encoded = try JSONEncoder().encode(request)
        let reread = try JSONDecoder().decode(RequestPermissionRequest.self, from: encoded)
        guard case .object(let input) = reread.toolCall.rawInput,
              case .string(let reencoded) = input["CommandLine"]
        else {
            Issue.record("rawInput.CommandLine missing after re-encoding")
            return
        }
        #expect(Data(reencoded.utf8) == Data(commandLine.utf8))
    }

    /// The blocker names the missing contract and the fail-closed expectation.
    @Test func blockerStatesMissingContractAndFailClosedExpectation() {
        let blocker = AntigravityCompat.mcpIdentityBlocker
        #expect(blocker.contains("agy_acp_server"))
        #expect(blocker.contains("configured MCP server identifier"))
        #expect(blocker.contains("exact original tool name"))
        #expect(blocker.contains("Refuse or ask"))
        #expect(blocker.contains("never infer"))
    }
}
