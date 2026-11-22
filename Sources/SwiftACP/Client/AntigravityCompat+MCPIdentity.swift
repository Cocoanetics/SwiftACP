import Foundation

/// Whether a tool call carries an MCP server/tool identity a host may act on.
///
/// There is deliberately no "available" case yet: SwiftACP adds typed access to an
/// identity only once the upstream wire shape and its binding are documented and
/// captured (see `AntigravityCompat.mcpToolIdentity(of:agentName:)`).
/// Until then every call answers ``unavailable(reason:)``, and a host must fail closed.
public enum MCPToolIdentityAvailability: Equatable, Sendable {
    /// No identity can be established; `reason` names the upstream blocker. The host
    /// refuses the call or asks a person — it never infers a server or tool.
    case unavailable(reason: String)
}

// MCP server/tool identity for Antigravity tool calls (#345, part of #343).
//
// ### The required upstream contract
//
// A host can only scope an allowlist to "tool T of configured MCP server S" when the
// trusted adapter supplies, under a versioned contract:
//
// - a unique identifier of one MCP server *as configured for the session*
//   (`session/new` / `session/load` `mcpServers`), unambiguous among them;
// - the exact original tool name from that server's catalog (`tools/list`), not a
//   flattened, prefixed or display form;
// - bound by the adapter to that configured server/catalog *and* to this specific
//   call (`toolCallId`), so a pair cannot be replayed onto another call.
//
// None of `title`, `kind`, `args`/`rawInput`, the `initialize` `agentInfo.name`, or a
// split of a flattened name such as `mcp_missioncontrol_view_issue` (server
// `missioncontrol` + tool `view_issue`? `missioncontrol_view` + `issue`?) establishes
// this binding. Even an explicit server/tool pair is only an adapter assertion until the
// host can validate its provenance and its mapping to the configured server.
//
// ### The upstream blocker
//
// SwiftACP launches the external `agy_acp_server` runtime and does not vendor it. The
// sanitized native permission shape it sends carries only the opaque flattened `name`
// (`mcp_missioncontrol_view_issue`), a display `title` ("Run mcp_missioncontrol_view_issue"),
// `kind`, `args` and `rawInput` — no server/tool pair and no documented identity
// extension. No such extension has been captured, so none is decoded here.
extension AntigravityCompat {
    /// Why no MCP server/tool identity is available — the upstream blocker and the
    /// fail-closed expectation it leaves the host with.
    public static let mcpIdentityBlocker =
        "MCP server/tool identity is unavailable: the external Antigravity ACP adapter "
        + "(agy_acp_server) sends only an opaque flattened tool name and a display title, "
        + "with no versioned contract binding a configured MCP server identifier and the "
        + "exact original tool name to this call. Refuse or ask; never infer a server or "
        + "tool from the name, title, kind, arguments or agent name."

    /// The MCP server/tool identity of a permission request's tool call: always
    /// ``MCPToolIdentityAvailability/unavailable(reason:)`` with ``mcpIdentityBlocker``.
    ///
    /// Nothing on the call or the connection is read to derive one — not ``ToolCallUpdate/name``,
    /// ``ToolCallUpdate/title``, ``ToolCallUpdate/kind``, ``ToolCallUpdate/args``,
    /// ``ToolCallUpdate/rawInput``, nor `agentName` — because none of them binds a configured
    /// server and its exact tool to the call. `agentName` is taken only so callers state
    /// which adapter they asked about; it never changes the answer.
    public static func mcpToolIdentity(
        of toolCall: ToolCallUpdate, agentName: String?
    ) -> MCPToolIdentityAvailability {
        .unavailable(reason: mcpIdentityBlocker)
    }

    /// The MCP server/tool identity of a `tool_call`: always
    /// ``MCPToolIdentityAvailability/unavailable(reason:)``, as for a permission request.
    public static func mcpToolIdentity(
        of toolCall: ToolCall, agentName: String?
    ) -> MCPToolIdentityAvailability {
        .unavailable(reason: mcpIdentityBlocker)
    }
}
