@testable import acpx
import SwiftMCP
import Testing

/// `set model` on the CLI side (#92): always a model selection, as acpx's
/// `handleSetConfigOption` hands the `model` key to `handleSetModel`, and a refusal from
/// the daemon in acpx's words.
struct SetModelCommandTests {
    @Test func theModelKeyIsAlwaysAModelSelection() {
        #expect(ControlCommand.resolveSetOperation(key: "model", agentCommand: "claude") == .model)
        #expect(ControlCommand.resolveSetOperation(key: "effort", agentCommand: "claude") == .configOption("effort"))
        #expect(ControlCommand.resolveSetOperation(
            key: "thought_level", agentCommand: "npx @zed-industries/codex-acp") == .configOption("reasoning_effort"))
    }

    /// The MCP client says `Tool call failed: <message>`; acpx says the message.
    @Test func aControlsRefusalIsTheDaemonsOwnMessage() {
        let message = #"Cannot set model "x": the ACP session did not advertise a model config option or "#
            + "legacy session/set_model support."
        let failure = DaemonClient.controlFailure(MCPServerProxyError.toolError(message))
        #expect(failure.localizedDescription == message)
        let other = DaemonClient.controlFailure(MCPServerProxyError.sessionInvalidated)
        #expect(other is MCPServerProxyError)
    }
}
