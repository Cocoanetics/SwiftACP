@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// A failed turn is reported as acpx's queue owner reports one to its CLI
/// (`sendQueuedTaskError`), and the CLI prints the report as acpx's formatters print
/// it (#84, #57). Expected lines are acpx 0.19.1's, from running both CLIs against the
/// same agents.
@Suite struct TurnFailureTests {
    /// The agent's answer to a prompt it failed, with details.
    static let overloaded = JSONRPCErrorBody(
        code: -32603, message: "Internal error", data: .object(["details": .string("model overloaded")]))
    /// The same error as the exchange showed it.
    static let overloadedOnTheWire = AcpErrorPayload(
        code: -32603, message: "Internal error", data: WireJSON(.object(["details": .string("model overloaded")])))
    static let refusedImage = UnsupportedPromptContentError(index: 1, capability: "image", agent: nil)
    static let refusedImageText =
        "prompt[1] image content requires agentCapabilities.promptCapabilities.image"

    static func event(_ error: Error, shown: AcpErrorPayload? = nil) -> TurnFailedEvent {
        TurnFailure.event(for: error, shown: shown, sessionId: "rec-1")
    }

    // MARK: What a failure is

    /// The agent's own error response, which the exchange showed: a runtime failure of
    /// the queued prompt, carrying the error as acpx's `acp` payload.
    @Test func anAgentErrorTheWireShowedIsTheQueuedPromptsRuntimeFailure() {
        let event = Self.event(Self.overloaded, shown: Self.overloadedOnTheWire)
        #expect(event.outputCode == "RUNTIME")
        #expect(event.detailCode == "QUEUE_RUNTIME_PROMPT_FAILED")
        #expect(event.origin == "runtime")
        #expect(event.message == "Internal error")
        #expect(event.shown)
        #expect(event.sessionId == "rec-1")
        #expect(event.acp.flatMap(AcpErrorPayload.init) == Self.overloadedOnTheWire)
    }

    /// `resolveOutputErrorCode`: a runtime failure saying the session is gone.
    @Test func aGoneSessionIsNoSession() {
        let event = Self.event(JSONRPCErrorBody(code: -32002, message: "Resource not found: session s-1"))
        #expect(event.outputCode == "NO_SESSION")
        #expect(!event.shown)
        #expect(event.acp.flatMap(AcpErrorPayload.init)?.code == -32002)
    }

    /// acpx's `UnsupportedPromptContentError`, raised before the prompt is sent.
    @Test func contentTheAgentCannotTakeIsAUsageError() {
        let event = Self.event(Self.refusedImage)
        #expect(event == TurnFailedEvent(
            outputCode: "USAGE", detailCode: "UNSUPPORTED_PROMPT_CONTENT", origin: "acp",
            message: Self.refusedImageText, acp: nil, shown: false, sessionId: "rec-1"))
        let resource = UnsupportedPromptContentError(index: 0, capability: "embeddedContext", agent: nil)
        #expect(resource.localizedDescription
            == "prompt[0] resource content requires agentCapabilities.promptCapabilities.embeddedContext")
    }

    @Test func anyOtherFailureIsTheQueuedPromptsRuntimeFailure() {
        struct Broken: LocalizedError { var errorDescription: String? { "broken pipe" } }
        #expect(Self.event(Broken()) == TurnFailedEvent(
            outputCode: "RUNTIME", detailCode: "QUEUE_RUNTIME_PROMPT_FAILED", origin: "runtime",
            message: "broken pipe", acp: nil, shown: false, sessionId: "rec-1"))
    }

    // MARK: How the CLI prints it

    /// The agent's error response is on the wire, so text output shows it where it
    /// arrived, after the partial reply; the report adds nothing.
    @Test func textOutputShowsTheAgentsErrorWhereItArrived() {
        let (out, err) = OutputRendererTests.capture(.text) { renderer in
            renderer.render(.agentMessageChunk(.text("partial ")))
            renderer.wireMessage(Self.inboundError(details: "model overloaded"))
            renderer.turnFailed(Self.event(Self.overloaded, shown: Self.overloadedOnTheWire))
        }
        #expect(out == "partial \n\n[error] RUNTIME: model overloaded\n")
        #expect(err.isEmpty)
    }

    /// Without details, the error shows by its message, with the hint that goes by it.
    @Test func textOutputShowsAnErrorWithoutDetailsByItsMessage() {
        let (out, _) = OutputRendererTests.capture(.text) { $0.wireMessage(Self.inboundError(details: nil)) }
        #expect(out == """
            [error] RUNTIME: Internal error
            hint: rerun with `--verbose` to capture the underlying ACP error details.

            """)
    }

    /// A failure the wire never showed is printed by the report.
    @Test func textOutputPrintsAFailureTheWireDidNotShow() {
        let (out, err) = OutputRendererTests.capture(.text) { $0.turnFailed(Self.event(Self.refusedImage)) }
        #expect(out == "[error] USAGE: \(Self.refusedImageText)\n")
        #expect(err.isEmpty)
    }

    /// acpx's quiet formatter always reports the failure: it flushes the reply so far,
    /// then gives the qualified code and the agent's details on one stderr line.
    @Test func quietOutputFlushesTheReplyThenSaysWhatFailed() {
        let (out, err) = OutputRendererTests.capture(.quiet) { renderer in
            renderer.render(.agentMessageChunk(.text("partial ")))
            renderer.wireMessage(Self.inboundError(details: "model overloaded"))
            renderer.turnFailed(Self.event(Self.overloaded, shown: Self.overloadedOnTheWire))
        }
        #expect(out == "partial \n")
        #expect(err == "[acpx] error: RUNTIME QUEUE_RUNTIME_PROMPT_FAILED model overloaded\n")
    }

    @Test func quietOutputWithoutAReplyIsJustTheErrorLine() {
        let (out, err) = OutputRendererTests.capture(.quiet) { $0.turnFailed(Self.event(Self.refusedImage)) }
        #expect(out.isEmpty)
        #expect(err == "[acpx] error: USAGE UNSUPPORTED_PROMPT_CONTENT \(Self.refusedImageText)\n")
    }

    /// JSON output streams the exchange, so an error it showed is not repeated; one it
    /// did not is printed as acpx's JSON-RPC error line, naming the session.
    @Test func jsonOutputPrintsOnlyAFailureTheStreamDidNotShow() {
        let shown = OutputRendererTests.capture(.json) {
            $0.turnFailed(Self.event(Self.overloaded, shown: Self.overloadedOnTheWire))
        }
        #expect(shown.out.isEmpty)
        let unshown = OutputRendererTests.capture(.json) { $0.turnFailed(Self.event(Self.refusedImage)) }
        #expect(unshown.out == #"""
            {"jsonrpc":"2.0","id":null,"error":{"code":-32602,"message":"\#(Self.refusedImageText)",\#
            "data":{"acpxCode":"USAGE","detailCode":"UNSUPPORTED_PROMPT_CONTENT","origin":"acp","sessionId":"rec-1"}}}

            """#)
        #expect(unshown.err.isEmpty)
    }

    /// An error from before the prompt attempt — a restore the agent refused while
    /// connecting — does not cover how the attempt fails. `exec` starts the attempt
    /// itself; a daemon turn's stream starts it at the turn's prompt.
    @Test func anErrorBeforeThePromptAttemptIsNotItsFailure() {
        let refusedMode = WireMessageEvent(
            wireDirection: "inbound",
            wireLine: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error"}}"#)
        let prompt = WireMessageEvent(
            wireDirection: "outbound", wireLine: #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{}}"#)
        let options = RenderOptions(format: .json, streamsWire: true)

        let exec = OutputRenderer(options: options, out: { _ in }, err: { _ in }, color: false)
        exec.wireMessage(refusedMode)
        #expect(exec.showedFailure(Self.refusedImageText))
        exec.promptAttemptStarts()
        #expect(!exec.showedFailure(Self.refusedImageText))

        let daemonTurn = OutputRenderer(options: options, out: { _ in }, err: { _ in }, color: false)
        daemonTurn.wireMessage(refusedMode)
        daemonTurn.wireMessage(prompt)
        #expect(!daemonTurn.showedFailure("model overloaded"))
    }

    /// The report arrives as a log notification, and fails the turn once the call ends.
    @Test func theReportIsKeptForWhenTheCallFails() async throws {
        let box = StopReasonBox()
        let logs = PromptLogRenderer(OutputRenderer(options: RenderOptions(format: .text)), stopReason: box)
        let event = Self.event(Self.refusedImage)
        // Never connected: the handler only needs it to be called with.
        let proxy = MCPServerProxy(config: .stdioHandles(server: ACPXDaemon(backend: ACPXDaemonBackend())))
        await logs.mcpServerProxy(
            proxy, didReceiveLog: LogMessage(level: .info, logger: "rec-1", data: try Self.json(event)))
        #expect(await box.failure == event)
        #expect(await box.value == nil)
    }

    // MARK: Exit codes

    /// `exec` and the top level take the codes, and the origin, from the error.
    @Test func contentTheAgentCannotTakeExitsAsAUsageError() {
        var err: [String] = []
        let renderer = OutputRenderer(
            options: RenderOptions(format: .quiet), out: { _ in }, err: { _ in }, color: false)
        let code = ExecCommand.reportFailure(Self.refusedImage, renderer: renderer, format: "quiet") { err.append($0) }
        #expect(code == ExitCodes.usage)
        #expect(err == ["[acpx] error: USAGE UNSUPPORTED_PROMPT_CONTENT \(Self.refusedImageText)"])

        var out: [String] = []
        let topLevel = TopLevelFailure.report(
            Self.refusedImage, arguments: ["--format", "json"], out: { out.append($0) }, err: { _ in })
        #expect(topLevel == ExitCodes.usage)
        #expect(out.first?.contains(#""acpxCode":"USAGE","detailCode":"UNSUPPORTED_PROMPT_CONTENT","origin":"acp""#)
            == true)
    }

    /// A failure the output already shows exits as its report classified it.
    @Test func aShownFailureExitsByItsReportedCode() {
        let shown = FailureAlreadyShown(underlying: Self.refusedImage, outputCode: "NO_SESSION")
        #expect(TopLevelFailure.report(shown, arguments: [], out: { _ in }, err: { _ in }) == ExitCodes.noSession)
    }

    // MARK: Helpers

    static func inboundError(details: String?) -> WireMessageEvent {
        let data = details.map { #","data":{"details":"\#($0)"}"# } ?? ""
        return WireMessageEvent(
            wireDirection: "inbound",
            wireLine: #"{"jsonrpc":"2.0","id":3,"error":{"code":-32603,"message":"Internal error"\#(data)}}"#)
    }

    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
