@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// A control's failure as the daemon describes it (``ToolFailure``, the tool error's `_meta`)
/// and as the CLI then reports it: as acpx reports the failure where the control ran (#171).
struct ControlFailureOutputTests {
    /// What the CLI reports for `error` under `format`.
    private static func report(_ error: Error, format: String) -> CLIRun {
        var out = ""
        var err = ""
        let code = TopLevelFailure.report(
            error, arguments: ["--format", format, "set-mode", "plan"], out: { out += $0 }, err: { err += $0 + "\n" })
        return CLIRun(code: code, out: out, err: err)
    }

    /// The daemon's failure `failure`, with `message`, as the CLI has it once the call failed.
    private static func fromDaemon(_ message: String, _ failure: ToolFailure) -> Error {
        DaemonClient.controlFailure(MCPServerProxyError.toolErrorWithMeta(message, meta: failure.meta))
    }

    @Test func aFailureGoesAsMetaAndComesBackAsItWent() throws {
        let failure = ToolFailure(
            outputCode: "RUNTIME", detailCode: "QUEUE_CONTROL_REQUEST_FAILED", origin: "queue", retryable: true,
            acp: ["code": -32602, "message": "Invalid params", "data": ["fixture": "mode"]])
        #expect(Array(failure.meta.keys) == ["acpx/error"])
        #expect(ToolFailure(meta: failure.meta) == failure)
        #expect(ToolFailure().isEmpty)
        #expect(!failure.isEmpty)
        #expect(ToolFailure(meta: ["other/key": "x"]) == nil)
    }

    /// An agent's error comes back as the agent's: its code, message and data in JSON, the
    /// daemon's text for quiet and text output, and the output code by what the daemon said.
    @Test func anAgentsRefusalIsReportedByItsOwnCodeAndData() {
        let message = #"Agent rejected session/set_mode for mode "plan": Invalid params (ACP -32602). "#
            + "The adapter may not implement session/set_mode, or the requested value is not supported."
        let error = Self.fromDaemon(message, ToolFailure(
            outputCode: "RUNTIME", detailCode: "QUEUE_CONTROL_REQUEST_FAILED", origin: "queue",
            acp: ["code": -32602, "message": "Invalid params", "data": ["fixture": "mode"]]))
        let json = Self.report(error, format: "json")
        #expect(json.code == 1)
        #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32602,"message":"Invalid params","data":"#
            + #"{"acpxCode":"RUNTIME","detailCode":"QUEUE_CONTROL_REQUEST_FAILED","origin":"queue","#
            + #""sessionId":"unknown","fixture":"mode"}}}"# + "\n")
        #expect(Self.report(error, format: "quiet").err
            == "[acpx] error: RUNTIME QUEUE_CONTROL_REQUEST_FAILED \(message)\n")
        #expect(Self.report(error, format: "text").err
            == "\(message)\nhint: rerun with `--verbose` to capture the ACP method/error details before retrying.\n")
    }

    /// An agent's error that says the session is gone is `NO_SESSION` by its code, as acpx's
    /// normalization finds the agent's error in the failure (`isAcpResourceNotFoundError`) —
    /// though its words say nothing of a session.
    @Test func anAgentsErrorForAGoneSessionIsNoSession() {
        let error = Self.fromDaemon("Gone", ToolFailure(acp: ["code": -32002, "message": "Gone"]))
        let json = Self.report(error, format: "json")
        #expect(json.code == 4)
        #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32002,"message":"Gone","data":"#
            + #"{"acpxCode":"NO_SESSION","origin":"cli","sessionId":"unknown"}}}"# + "\n")
    }

    /// A control past its `--timeout` is `TIMEOUT` (exit 3, with its hint) by what the daemon
    /// said — an owner's with the owner's detail code and origin, as acpx's owner answers it.
    @Test(arguments: [false, true])
    func aControlPastItsTimeoutIsATimeout(owned: Bool) {
        let error = Self.fromDaemon("Timed out after 300ms", owned
            ? ToolFailure(outputCode: "TIMEOUT", detailCode: "QUEUE_CONTROL_REQUEST_FAILED", origin: "queue")
            : ToolFailure(outputCode: "TIMEOUT"))
        let qualifier = owned ? "TIMEOUT QUEUE_CONTROL_REQUEST_FAILED" : "TIMEOUT"
        let quiet = Self.report(error, format: "quiet")
        #expect(quiet.code == 3)
        #expect(quiet.err == "[acpx] error: \(qualifier) Timed out after 300ms\n")
        #expect(Self.report(error, format: "text").err == "Timed out after 300ms\nhint: increase `--timeout "
            + "<seconds>` for long-running prompts, or check whether the agent/provider is stalled.\n")
        let origin = owned ? #""detailCode":"QUEUE_CONTROL_REQUEST_FAILED","origin":"queue""# : #""origin":"cli""#
        #expect(Self.report(error, format: "json").out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32070,"#
            + #""message":"Timed out after 300ms","data":{"acpxCode":"TIMEOUT","# + origin
            + #","sessionId":"unknown"}}}"# + "\n")
    }

    /// A failure the daemon said nothing more of is a runtime failure by its message, as before.
    @Test func aFailureWithoutMetaIsARuntimeFailure() {
        let message = "acpxd is stopping and starts no more agents"
        let error = DaemonClient.controlFailure(MCPServerProxyError.toolError(message))
        let json = Self.report(error, format: "json")
        #expect(json.code == 1)
        #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"#
            + #""message":"acpxd is stopping and starts no more agents","data":{"acpxCode":"RUNTIME","origin":"cli","#
            + #""sessionId":"unknown"}}}"# + "\n")
    }
}

/// How a run of the CLI went: its exit code, and what it wrote to stdout and stderr.
struct CLIRun {
    let code: Int32
    let out: String
    let err: String
}
