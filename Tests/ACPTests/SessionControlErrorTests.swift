@testable import ACPXCore
import Foundation
import JSONFoundation
import JSONRPCPeer
import SwiftACP
import Testing

/// A session control the agent turns down, said as acpx 0.19.1's client says it
/// (`session-control-errors.ts`, #164): an error that looks like the control is not
/// supported is wrapped, naming the control and what was asked; a model's other errors
/// are too; the agent's error stays the failure's own.
struct SessionControlErrorTests {
    private func agentError(_ code: Int, _ message: String, details: String? = nil) -> JSONRPCErrorBody {
        JSONRPCErrorBody(code: code, message: message, data: details.map { .object(["details": .string($0)]) })
    }

    private func said(_ error: Error) -> String { TurnFailure.message(of: error) }

    @Test func aModeTheAgentDoesNotTakeIsRejected() {
        let error = SessionControlError.wrap(
            agentError(-32602, "Invalid params"), method: "session/set_mode", context: "for mode \"plan\"")
        #expect(said(error) == #"Agent rejected session/set_mode for mode "plan": Invalid params (ACP -32602). "#
            + "The adapter may not implement session/set_mode, or the requested value is not supported.")
        #expect(TurnFailure.payload(of: error) == AcpErrorPayload(code: -32602, message: "Invalid params"))
    }

    /// Method not found is as good as a rejection; an internal error only when its details
    /// say invalid params — and then the details are what it says, naming what the adapter
    /// reported.
    @Test func whatLooksLikeARejection() {
        let context = #"for "thought"="high""#
        let notFound = SessionControlError.wrap(
            agentError(-32601, "Method not found"), method: "session/set_config_option", context: context)
        #expect(said(notFound).hasPrefix(
            #"Agent rejected session/set_config_option for "thought"="high": Method not found (ACP -32601). "#))
        let internalError = SessionControlError.wrap(
            agentError(-32603, "Internal error", details: " Invalid params: mode unknown "), method: "session/set_mode",
            context: "for mode \"plan\"")
        #expect(said(internalError).hasPrefix(#"Agent rejected session/set_mode for mode "plan": Invalid params: "#
            + #"mode unknown (ACP -32603, adapter reported "Internal error")."#))
        let other = agentError(-32603, "Internal error", details: "disk full")
        #expect(said(SessionControlError.wrap(other, method: "session/set_mode", context: "")) == "Internal error")
        #expect(said(SessionControlError.wrap(agentError(-32000, "boom"), method: "session/set_mode", context: ""))
            == "boom")
    }

    /// A model the agent fails otherwise is `Failed <method> for model "<id>"`, the agent's
    /// error by its summary and anything else by its message.
    @Test func aModelsOtherFailuresSayWhichModel() {
        let boom = SessionControlError.model(
            agentError(-32000, "boom"), method: "session/set_config_option", modelId: "b")
        #expect(said(boom) == #"Failed session/set_config_option for model "b": boom (ACP -32000)"#)
        #expect(TurnFailure.payload(of: boom)?.code == -32000)
        let closed = SessionControlError.model(JSONRPCPeerError.closed, method: "session/set_model", modelId: "b")
        #expect(said(closed) == #"Failed session/set_model for model "b": ACP connection closed"#)
        let rejected = SessionControlError.model(
            agentError(-32602, "Invalid params"), method: "session/set_model", modelId: "b")
        #expect(said(rejected).hasPrefix(#"Agent rejected session/set_model for model "b": "#))
    }

    /// A connection that ended under a control still ended: the wrapped error keeps what it
    /// came of as its cause, as acpx's does, and the connection's checks look through it.
    @Test func aConnectionThatEndedUnderAControlStillEnded() {
        let closed = SessionControlError.model(JSONRPCPeerError.closed, method: "session/set_model", modelId: "b")
        #expect(ACPAgentConnection.isConnectionClosed(closed))
        #expect(ACPAgentConnection.endedTheConnection(closed))
        let boom = SessionControlError.model(agentError(-32000, "boom"), method: "session/set_model", modelId: "b")
        #expect(!ACPAgentConnection.endedTheConnection(boom))
    }

    /// A control called off is still just called off.
    @Test func aCancelledControlIsNotWrapped() async {
        await #expect(throws: CancellationError.self) {
            try await SessionControlError.wrappingModel("session/set_model", modelId: "b") { throw CancellationError() }
        }
    }
}
