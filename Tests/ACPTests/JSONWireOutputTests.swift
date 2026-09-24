@testable import ACPXCore
@testable import acpx
import Foundation
import JSONRPCPeer
import SwiftACP
import Testing

/// `exec --format json` as acpx writes it: the ACP exchange itself, re-serialized as
/// `JSON.stringify` prints it; read output suppressed under `--suppress-reads`; a
/// failure the stream did not already show as one JSON-RPC error line. Expected lines
/// marked "acpx" were printed by npm acpx 0.19.1 for the same input.
@Suite struct JSONWireOutputTests {
    private static func json(_ text: String) throws -> WireJSON { try #require(WireJSON(parsing: text)) }

    private static func toolUpdate(_ fields: String) throws -> WireJSON {
        try json(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"#
            + fields + "}}}")
    }

    // MARK: - Sanitizer

    @Test func aReadResultIsSuppressedInPlace() throws {
        var sanitizer = JSONMessageSanitizer(suppressReads: true)
        let request = try Self.json(#"{"jsonrpc":"2.0","id":"r1","method":"fs/read_text_file","params":{"path":"/a"}}"#)
        #expect(sanitizer.sanitize(request, direction: .inbound) == request)
        let response = try Self.json(#"{"jsonrpc":"2.0","id":"r1","result":{"content":"secret","line":3}}"#)
        #expect(sanitizer.sanitize(response, direction: .outbound).stringified
            == #"{"jsonrpc":"2.0","id":"r1","result":{"content":"[read output suppressed]","line":3}}"#)
    }

    /// A response answers the request that travelled the other way with its id; any
    /// other response — a write's, or one that pairs with nothing — is left alone.
    @Test func onlyTheReadsOwnResponseIsSuppressed() throws {
        var sanitizer = JSONMessageSanitizer(suppressReads: true)
        _ = sanitizer.sanitize(
            try Self.json(#"{"jsonrpc":"2.0","id":7,"method":"fs/read_text_file","params":{}}"#), direction: .inbound)
        let sameDirection = try Self.json(#"{"jsonrpc":"2.0","id":7,"result":{"content":"kept"}}"#)
        #expect(sanitizer.sanitize(sameDirection, direction: .inbound) == sameDirection)

        _ = sanitizer.sanitize(
            try Self.json(#"{"jsonrpc":"2.0","id":"w1","method":"fs/write_text_file","params":{}}"#),
            direction: .inbound)
        let ack = try Self.json(#"{"jsonrpc":"2.0","id":"w1","result":{"content":"not a read"}}"#)
        #expect(sanitizer.sanitize(ack, direction: .outbound) == ack)
    }

    /// A later update may name neither title nor kind; what the tool said of itself
    /// earlier still applies. Output as acpx printed it for the same update.
    @Test func aReadLikeToolsOutputIsSuppressedAcrossItsUpdates() throws {
        var sanitizer = JSONMessageSanitizer(suppressReads: true)
        let call = try Self.toolUpdate(
            #""sessionUpdate":"tool_call","toolCallId":"t1","title":"Read notes.txt","kind":"read","status":"pending""#)
        #expect(sanitizer.sanitize(call, direction: .inbound) == call)
        let update = try Self.toolUpdate(#""sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","#
            + #""content":[{"type":"content","content":{"type":"text","text":"secret file body"}}],"#
            + #""rawOutput":{"content":"secret file body"}"#)
        #expect(sanitizer.sanitize(update, direction: .inbound).stringified
            == #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"#
            + #""sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","#
            + #""content":[{"type":"content","content":{"type":"text","text":"[read output suppressed]"}}],"#
            + #""rawOutput":{"content":"[read output suppressed]"}}}}"#)
    }

    /// An explicit `kind: null` clears an earlier kind; the title alone then decides.
    @Test func aNullKindClearsAnEarlierReadKind() throws {
        var sanitizer = JSONMessageSanitizer(suppressReads: true)
        _ = sanitizer.sanitize(
            try Self.toolUpdate(#""sessionUpdate":"tool_call","toolCallId":"t2","title":"Summarize","kind":"read""#),
            direction: .inbound)
        let cleared = try Self.toolUpdate(
            #""sessionUpdate":"tool_call_update","toolCallId":"t2","kind":null,"rawOutput":{"content":"x"}"#)
        #expect(sanitizer.sanitize(cleared, direction: .inbound) == cleared)
    }

    @Test func withoutSuppressReadsNothingChanges() throws {
        var sanitizer = JSONMessageSanitizer(suppressReads: false)
        let update = try Self.toolUpdate(
            #""sessionUpdate":"tool_call","toolCallId":"t3","kind":"read","rawOutput":{"content":"secret"}"#)
        #expect(sanitizer.sanitize(update, direction: .inbound) == update)
    }

    // MARK: - Which failures the stream already shows

    @Test func theAgentsLatestErrorCoversAnyFailure() throws {
        var tracker = AcpErrorTracker()
        #expect(tracker.match(failureText: "boom") == nil)
        tracker.observe(
            try Self.json(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error","#
                + #""data":{"details":"model exploded"}}}"#),
            direction: .inbound)
        #expect(tracker.match(failureText: "anything at all")?.message == "Internal error")
    }

    /// The client's own refusal covers only the failure that repeats it — by
    /// `data.details` when it has them.
    @Test func aClientRefusalCoversOnlyTheFailureThatRepeatsIt() throws {
        var tracker = AcpErrorTracker()
        tracker.observe(
            try Self.json(#"{"jsonrpc":"2.0","id":"w1","error":{"code":-32603,"message":"Internal error","#
                + #""data":{"details":"Permission prompt unavailable in non-interactive mode"}}}"#),
            direction: .outbound)
        #expect(tracker.match(failureText: "Permission prompt unavailable in non-interactive mode") != nil)
        #expect(tracker.match(failureText: "The JSON-RPC connection is closed") == nil)
    }

    /// Each attempt at the prompt starts afresh — acpx resets its tracker as the attempt
    /// starts, before it checks and sends the prompt — so an error from connecting the
    /// agent does not stand in for how the attempt fails.
    @Test func eachPromptAttemptStartsTheTrackerAfresh() throws {
        var tracker = AcpErrorTracker()
        tracker.observe(
            try Self.json(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Mode rejected"}}"#),
            direction: .inbound)
        tracker.observe(
            try Self.json(#"{"jsonrpc":"2.0","id":"w1","error":{"code":-32603,"message":"refused"}}"#),
            direction: .outbound)
        // Seeing the prompt go out is no reset: the attempt starts before it.
        tracker.observe(
            try Self.json(#"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{}}"#), direction: .outbound)
        #expect(tracker.match(failureText: "anything at all")?.message == "Mode rejected")
        tracker.reset()
        #expect(tracker.match(failureText: "refused") == nil)
        #expect(tracker.match(failureText: "anything at all") == nil)

        tracker.observe(
            try Self.json(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32603,"message":"Internal error"}}"#),
            direction: .inbound)
        #expect(tracker.match(failureText: "anything at all")?.message == "Internal error")
    }

    // MARK: - The error line

    @Test func errorLinesAreAcpxs() {
        // acpx: `exec` under `disableExec: true`.
        #expect(JSONErrorLine.make(
            outputCode: "EXEC_DISABLED", origin: "cli",
            message: "exec subcommand is disabled by configuration (disableExec: true)", sessionId: "unknown")
            == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"exec subcommand is disabled by "#
            + #"configuration (disableExec: true)","data":{"acpxCode":"EXEC_DISABLED","origin":"cli","#
            + #""sessionId":"unknown"}}}"#)
        // acpx: an agent command that does not exist.
        let spawn = AgentLaunchError(
            agentCommand: "/nonexistent/agent-binary", workingDirectory: nil, detailCode: AgentLaunchError.spawnENOENT)
        let spawnLine = JSONErrorLine.make(
            outputCode: "RUNTIME", detailCode: spawn.detailCode, origin: "cli", message: spawn.localizedDescription,
            sessionId: "unknown")
        #expect(spawnLine.hasPrefix(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Failed to spawn "#
            + #"agent command: /nonexistent/agent-binary. The agent process could not start"#))
        #expect(spawnLine.hasSuffix(#""data":{"acpxCode":"RUNTIME","detailCode":"AGENT_SPAWN_ENOENT","origin":"cli","#
            + #""sessionId":"unknown"}}}"#))
        #expect(JSONErrorLine.make(outputCode: "PERMISSION_PROMPT_UNAVAILABLE", message: "m")
            == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32072,"message":"m","#
            + #""data":{"acpxCode":"PERMISSION_PROMPT_UNAVAILABLE"}}}"#)
    }

    /// An ACP error's own code and message win, and its data object is spread over the
    /// fallback fields — `{...fallback, ...data}`, as Node orders it.
    @Test func anACPErrorsDataIsSpreadOverTheFallback() {
        let acp = AcpErrorPayload(
            code: -32000, message: "Auth required",
            data: .object([.init("origin", .text("agent")), .init("hint", .text("login"))]))
        #expect(JSONErrorLine.make(outputCode: "RUNTIME", origin: "cli", message: "x", sessionId: "unknown", acp: acp)
            == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Auth required","#
            + #""data":{"acpxCode":"RUNTIME","origin":"agent","sessionId":"unknown","hint":"login"}}}"#)
    }

    // MARK: - Reporting a failed run

    private static func capturingRenderer() -> (OutputRenderer, OutputRendererTests.Capture) {
        let out = OutputRendererTests.Capture()
        let renderer = OutputRenderer(
            options: RenderOptions(format: .json, streamsWire: true), out: out.write, err: { _ in }, color: false)
        return (renderer, out)
    }

    /// The agent's error response is already on the stream: nothing more is printed.
    @Test func aFailureTheStreamShowedAddsNothing() {
        let (renderer, out) = Self.capturingRenderer()
        let response = #"{"jsonrpc":"2.0","id":3,"error":{"code":-32603,"message":"Internal error"}}"#
        renderer.acpMessage(.inbound, Data(response.utf8))
        let code = ExecCommand.reportJSONFailure(
            JSONRPCErrorBody(code: -32603, message: "Internal error"), renderer: renderer)
        #expect(code == ExitCodes.error)
        #expect(out.text == response + "\n")
    }

    @Test func aFailureOffTheWireGetsOneErrorLine() {
        let (renderer, out) = Self.capturingRenderer()
        let spawn = AgentLaunchError(agentCommand: "ghost", workingDirectory: nil, detailCode: nil)
        #expect(ExecCommand.reportJSONFailure(spawn, renderer: renderer) == ExitCodes.error)
        #expect(out.text == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Failed to spawn agent "#
            + #"command: ghost","data":{"acpxCode":"RUNTIME","origin":"cli","sessionId":"unknown"}}}"# + "\n")
    }

    /// A write nobody could confirm: silent when the client's refusal on the stream
    /// already says so, an error line otherwise — exit 5 either way.
    @Test func anUnanswerableWriteIsReportedOnce() {
        let (renderer, out) = Self.capturingRenderer()
        #expect(ExecCommand.reportJSONFailure(ExecCommand.PromptUnavailable(), renderer: renderer)
            == ExitCodes.permissionDenied)
        #expect(out.text.contains(#""code":-32072"#))

        let (shown, shownOut) = Self.capturingRenderer()
        let refusal = #"{"jsonrpc":"2.0","id":"w1","error":{"code":-32603,"message":"Internal error","#
            + #""data":{"details":"Permission prompt unavailable in non-interactive mode"}}}"#
        shown.acpMessage(.outbound, Data(refusal.utf8))
        #expect(ExecCommand.reportJSONFailure(ExecCommand.PromptUnavailable(), renderer: shown)
            == ExitCodes.permissionDenied)
        #expect(shownOut.text == refusal + "\n")
    }

    /// A prompt turn whose failure the JSON stream showed — the agent's error response —
    /// reaches the top level as already shown: nothing more is printed, and the exit
    /// code is still the failure's (acpx's `outputAlreadyEmitted`). Anything else is
    /// reported as before.
    @Test func aPromptFailureTheStreamShowedIsNotReportedAgain() {
        let failure = JSONRPCErrorBody(code: -32002, message: "Resource not found: session s")
        let (renderer, out) = Self.capturingRenderer()
        #expect(!(PromptCommand.turnFailure(failure, renderer: renderer) is FailureAlreadyShown))

        let prompt = #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"s","prompt":[]}}"#
        let response = #"{"jsonrpc":"2.0","id":3,"error":{"code":-32002,"message":"Resource not found: session s"}}"#
        renderer.wireMessage(WireMessageEvent(wireDirection: "outbound", wireLine: prompt))
        renderer.wireMessage(WireMessageEvent(wireDirection: "inbound", wireLine: response))
        let shown = PromptCommand.turnFailure(failure, renderer: renderer)
        #expect(shown is FailureAlreadyShown)

        var reported = ""
        let code = TopLevelFailure.report(
            shown, arguments: ["--format", "json", "mock", "hi"], out: { reported += $0 }, err: { reported += $0 })
        #expect(reported.isEmpty)
        #expect(code == ExitCodes.noSession)
        #expect(out.text == prompt + "\n" + response + "\n")

        // Text mode prints no wire, so nothing there counts as shown.
        let text = OutputRenderer(
            options: RenderOptions(format: .text, streamsWire: true), out: { _ in }, err: { _ in }, color: false)
        text.wireMessage(WireMessageEvent(wireDirection: "inbound", wireLine: response))
        #expect(!(PromptCommand.turnFailure(failure, renderer: text) is FailureAlreadyShown))
    }

    // MARK: - The renderer in wire mode

    @Test func wireModePrintsTheExchangeAndNothingElse() {
        let (renderer, out) = Self.capturingRenderer()
        let spaced = #"{"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": "#
            + #"{"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hé"}}}}"#
        renderer.acpMessage(.inbound, Data(spaced.utf8))
        renderer.render(.agentMessageChunk(.text("hé")))
        renderer.clientOperation(OutputRendererTests.permissionNotice())
        renderer.finish(stopReason: .endTurn)
        #expect(out.text == #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hé"}}}}"# + "\n")
    }

    @Test func otherModesIgnoreTheWire() {
        for format in [OutputFormat.text, .quiet] {
            let out = OutputRendererTests.Capture()
            let renderer = OutputRenderer(
                options: RenderOptions(format: format, streamsWire: true), out: out.write, err: { _ in }, color: false)
            renderer.acpMessage(.inbound, Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            #expect(out.text.isEmpty)
        }
    }

    // MARK: - End to end

    /// What `exec --format json` prints for a real turn: both directions from the
    /// handshake on, the agent's lines re-serialized (the mock writes `json.dumps`
    /// spacing), ending with the prompt's response.
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnIsPrintedAsTheWholeExchange() async throws {
        let command = try #require(mockCommand())
        let (renderer, out) = Self.capturingRenderer()
        let agent = try await ACPAgent.launch(
            agent: command, cwd: NSTemporaryDirectory(), permission: .approveAll, inheritStderr: false,
            onRawWire: { renderer.acpMessage($0, $1) })
        let created = try await agent.connection.newSession(
            NewSessionRequest(cwd: NSTemporaryDirectory(), mcpServers: []))
        let session = ACPSession(id: created.sessionId, agent: agent, modes: created.modes)
        try await session.run([.text("ping")]) { renderer.render($0) }
        await agent.close()

        let lines = out.text.split(separator: "\n").map(String.init)
        let messages = try lines.map { try #require(WireJSON(parsing: $0)) }
        let methods = messages.compactMap { $0["method"]?.stringValue }
        #expect(methods.first == "initialize")
        #expect(methods.contains("session/new"))
        #expect(methods.filter { $0 == "session/update" }.count >= 5)
        #expect(messages.last?["result"]?["stopReason"]?.stringValue == "end_turn")
        // Every line is already in JSON.stringify form.
        #expect(zip(lines, messages).allSatisfy { $0 == $1.stringified })
        #expect(lines.contains(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"mock-session-1","#
            + #""update":{"sessionUpdate":"plan","entries":[{"content":"Read the request","status":"completed","#
            + #""priority":"high"},{"content":"Compose a reply","status":"in_progress","priority":"medium"}]}}}"#))
    }
}
