import ACPXCore
import Foundation
import JSONFoundation
import JSONRPCPeer
import SwiftACP

// A faithful port of acpx's `src/cli/output/output.ts` text + quiet rendering:
// a per-tool state machine that prints each tool once on start and once on its
// final status (deduped by signature), structured `[tool]/[plan]/[thinking]/
// [done]` sections, and read-output suppression. The whole transcript goes to
// stdout in text mode; quiet mode emits only the assistant's final text.
//
// The rest of output.ts lives next door: block limiting + text helpers in
// `OutputLimits.swift`, error remediation hints in `RemediationHints.swift`.

// MARK: - Constants (match output.ts)

private let MAX_THOUGHT_CHARS = 900
let SUPPRESSED_READ_OUTPUT = "[read output suppressed]"

// MARK: - Output format

enum OutputFormat: Sendable { case text, json, quiet }

struct RenderOptions: Sendable {
    var format: OutputFormat = .text
    /// Replace read-like tools' output with `[read output suppressed]`.
    var suppressReads = false
    /// JSON mode prints the ACP exchange itself, as acpx does — fed through
    /// ``OutputRenderer/acpMessage(_:_:)`` — rather than the decoded updates.
    var streamsWire = false
}

/// Renders a turn's `SessionUpdate`s. One instance per turn; access is serial
/// (the run loop invokes it from a single task), guarded for `@Sendable` use.
final class OutputRenderer: @unchecked Sendable {
    let options: RenderOptions
    let lock = NSLock()
    /// Where the transcript (stdout) and the quiet-mode notices (stderr) go — the
    /// console by default; tests capture them.
    let out: @Sendable (String) -> Void
    let err: @Sendable (String) -> Void
    private let useColor: Bool

    // Text-mode state
    private var toolStates: [String: ToolRenderState] = [:]
    private var thoughtBuffer = ""
    private var wroteAny = false
    private var atLineStart = true

    // Quiet-mode buffer
    var quietChunks: [String] = []
    /// Whether the turn's end was rendered: acpx's formatters mark it at the prompt's
    /// answer, and render what comes after as it comes — but quiet mode none of its text.
    private var finished = false

    // JSON wire-mode state
    private var sanitizer: JSONMessageSanitizer
    var shownErrors = AcpErrorTracker()
    private var renderingDelay: (@Sendable () async -> Void)?

    init(
        options: RenderOptions,
        out: @escaping @Sendable (String) -> Void = Console.out,
        err: @escaping @Sendable (String) -> Void = Console.err,
        color: Bool? = nil
    ) {
        self.options = options
        self.out = out
        self.err = err
        self.useColor = color ?? (isatty(fileno(stdout)) != 0)
        self.sanitizer = JSONMessageSanitizer(suppressReads: options.suppressReads)
    }

    /// For tests: runs before each event of an attempt is rendered, so that rendering can
    /// lag the agent without blocking a thread.
    var beforeRenderingEvent: (@Sendable () async -> Void)? {
        get { lock.withLock { renderingDelay } }
        set { lock.withLock { renderingDelay = newValue } }
    }

    /// JSON mode printing the exchange: every other entry point stays silent in it.
    var streamsWireJSON: Bool { options.format == .json && options.streamsWire }

    // MARK: JSON wire mode

    /// One message body as it crossed the wire: printed, in JSON wire mode, the way
    /// acpx's json formatter prints it — `JSON.stringify` of the parsed message, read
    /// output suppressed under `--suppress-reads` — and remembered if it carries an
    /// error. A body that is not JSON never reached the client as a message either.
    func acpMessage(_ direction: JSONRPCPeer.WireDirection, _ body: Data) {
        guard streamsWireJSON, let message = WireJSON(parsing: body) else { return }
        lock.lock()
        defer { lock.unlock() }
        shownErrors.observe(message, direction: direction)
        out(sanitizer.sanitize(message, direction: direction).stringified + "\n")
    }

    /// A message from the daemon's wire. JSON wire mode prints it as ``acpMessage``
    /// does; text mode shows a request or notification the way acpx's formatter does,
    /// as `[client] <method> (running)` — which is what connecting the agent for a turn
    /// looks like (the daemon streams the rest of a text-mode turn as updates).
    func wireMessage(_ event: WireMessageEvent) {
        let direction: JSONRPCPeer.WireDirection = event.wireDirection == "outbound" ? .outbound : .inbound
        if streamsWireJSON {
            // The daemon starts each attempt at the turn's prompt: what came before no
            // longer says how the turn fails.
            let body = Data(event.wireLine.utf8)
            if direction == .outbound, WireJSON(parsing: body)?["method"] == .text("session/prompt") {
                promptAttemptStarts()
            }
            acpMessage(direction, body)
            return
        }
        guard let message = WireJSON(parsing: Data(event.wireLine.utf8)) else { return }
        // An error response, either way, is shown as an error, as acpx's text formatter
        // shows one (`parseJsonRpcErrorSummary`: its details, else its message).
        if options.format == .text, !message.hasMember("method"), let error = AcpErrorPayload.extract(from: message) {
            renderError(code: "RUNTIME", error.details ?? error.message)
            return
        }
        guard let method = message["method"]?.stringValue,
            !["session/prompt", "session/cancel", "session/update"].contains(method)
        else { return }
        clientOperation(method)
    }

    /// acpx's `onPermissionEscalation` details, one per line.
    static func escalationDetails(_ escalation: PermissionEscalation) -> String {
        [
            "sessionId: \(escalation.sessionId)",
            "toolCallId: \(escalation.toolCallId)",
            escalation.toolName.map { "toolName: \($0)" },
            "toolTitle: \(escalation.toolTitle)",
            escalation.toolInput.map { "toolInput: \(ToolText.summarizeInput($0) ?? "(structured input)")" },
            escalation.toolKind.map { "toolKind: \($0)" },
            escalation.matchedRule.map { "matchedRule: \($0)" }
        ].compactMap { $0 }.joined(separator: "\n")
    }

    // MARK: Entry points

    func render(_ update: SessionUpdate) {
        lock.lock()
        defer { lock.unlock() }
        switch options.format {
        case .json: if !options.streamsWire { out(encodeLineJSON(update) + "\n") }
        case .quiet: renderQuiet(update)
        case .text: renderText(update)
        }
    }

    /// acpx's quiet `flushMetadata`: after the reply, the prompt response's token usage
    /// and cost on stderr, each when present (see ``QuietMetadata``). Other formats
    /// report neither.
    func promptMetadata(usage: WireJSON?, cost: WireJSON?) {
        guard options.format == .quiet else { return }
        if let line = QuietMetadata.usageLine(usage) { err(line + "\n") }
        if let line = QuietMetadata.costLine(cost) { err(line + "\n") }
    }

    func finish(stopReason: StopReason, answered: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        switch options.format {
        case .json:
            // The exchange already ended with the prompt's response.
            if !options.streamsWire { out(encodeLineJSON(["stopReason": stopReason.rawValue]) + "\n") }
        case .quiet:
            flushQuiet()
        case .text:
            flushThoughtBuffer()
            // acpx marks a turn done at its answer: one that ended without, cancelled before
            // its prompt went out or between attempts, is not marked.
            if answered {
                beginSection()
                writeLine(dim("[done] \(stopReason.rawValue)"))
            }
            if !atLineStart { write("\n") }
        }
    }

    /// acpx's text formatter `flush()`, which a run ends with however it went: what the
    /// agent was thinking is shown, and a line left open is ended.
    func flushText() {
        lock.lock()
        defer { lock.unlock() }
        guard options.format == .text else { return }
        flushThoughtBuffer()
        if !atLineStart { write("\n") }
    }

    /// Render a client-side ACP operation (e.g. `initialize`, `session/new`) as
    /// `[client] <method> (running)`. Mirrors acpx's `onClientOperation`, which
    /// keys off the outgoing request method observed on the wire.
    func clientOperation(_ method: String) {
        lock.lock()
        defer { lock.unlock() }
        guard options.format == .text else { return }
        flushThoughtBuffer()
        beginSection()
        writeLine("\(bold("[client]")) \(method) (\(colorStatus("running", nil)))")
    }

    /// Render a request the agent made of the client, the way acpx's formatter renders
    /// what it sees on the wire: the request as `[client] <method> (running)`, and the
    /// client's refusal as `[error] RUNTIME: <reason>`. Text mode only — acpx's quiet
    /// mode prints neither, and its JSON mode is the raw stream (see issue #50).
    func inboundRequest(_ request: InboundRequest) {
        if let failure = request.failure {
            // The client's refusal, which the stream shows — noted as acpx's tracker
            // notes an outbound error, so a failure repeating it is not printed again.
            let refusal = WireJSON.object([
                .init("error", .object([
                    .init("code", .number(-32603)), .init("message", .text("Internal error")),
                    .init("data", .object([.init("details", .text(failure))]))
                ]))
            ])
            lock.withLock { shownErrors.observe(refusal, direction: .outbound) }
            renderError(code: "RUNTIME", failure)
        } else {
            clientOperation(request.method)
        }
    }

    /// Render a client-side operation the connection reported during the turn —
    /// today a permission notice: the refusal it sent Codex may end the turn (see
    /// `CodexCompat`). Mirrors acpx's formatters: text mode prints
    /// `[permission] <notice>` (any other operation as `[client] <summary> (<status>)`
    /// plus its details), quiet mode writes `[acpx] permission: <notice>` to stderr
    /// on one line, and JSON mode emits the operation as a line.
    func clientOperation(_ operation: ClientOperation) {
        lock.lock()
        defer { lock.unlock() }
        let isPermissionNotice = operation.method == ClientOperation.requestPermission
        switch options.format {
        case .json:
            // On the wire this is the request and the client's answer, already printed.
            if !options.streamsWire { out(encodeLineJSON(operation) + "\n") }
        case .quiet:
            // acpx's quiet formatter prints nothing for an escalation.
            guard isPermissionNotice, operation.escalation == nil else { return }
            let oneLine = normalizeLineEndings(operation.summary).replacingOccurrences(of: "\n", with: " ")
            err("[acpx] permission: \(oneLine)\n")
        case .text:
            flushThoughtBuffer()
            beginSection()
            if isPermissionNotice {
                writeLine("\(bold("[permission]")) \(operation.summary)")
                if let escalation = operation.escalation {
                    writeLine(indentBlock(Self.escalationDetails(escalation), "  "))
                }
                return
            }
            writeLine("\(bold("[client]")) \(operation.summary) (\(colorStatus(operation.status)))")
            if let details = operation.details,
                !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                writeLine("  details:")
                writeLine(indentBlock(details, "    "))
            }
        }
    }

    /// Render a turn failure as `[error] <code>: <message>` (text mode only).
    /// Mirrors acpx's `onError`, which the wire-driven formatter emits on a
    /// JSON-RPC error response. The raw message is also surfaced on stderr by the
    /// command's `CLIError` handler.
    func renderError(
        code: String, _ message: String, acp: AcpErrorPayload? = nil, detailCode: String? = nil,
        origin: String = "acp"
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard options.format == .text else { return }
        flushThoughtBuffer()
        beginSection()
        writeLine(ansi("[error] \(code): \(message)", "31"))
        // The formatter renders a wire error as acp-origin.
        for hint in remediationHints(code: code, origin: origin, detailCode: detailCode, message: message, acp: acp) {
            writeLine(dim(hint))
        }
    }

    // MARK: Quiet mode

    private func renderQuiet(_ update: SessionUpdate) {
        if case .agentMessageChunk(let block) = update, let text = block.text, !finished {
            quietChunks.append(text)
        }
    }

    private func flushQuiet() {
        let text = quietChunks.joined()
        // Written once: acpx's `flushBufferedOutput` empties what it wrote.
        quietChunks = []
        out(text.hasSuffix("\n") ? text : text + "\n")
    }

    // MARK: Text mode

    private func renderText(_ update: SessionUpdate) {
        // Any non-thought update flushes the pending thought buffer first.
        if case .agentThoughtChunk = update {} else { flushThoughtBuffer() }

        switch update {
        case .agentMessageChunk(let block):
            if let text = block.text { writeAssistantChunk(text) }
        case .agentThoughtChunk(let block):
            if let text = block.text { thoughtBuffer += text }
        case .userMessageChunk:
            break
        case .toolCall(let call):
            renderTool(
                id: call.toolCallId, title: call.title, status: call.status, kind: call.kind,
                locations: call.locations, rawInput: call.rawInput, rawOutput: call.rawOutput,
                content: call.content)
        case .toolCallUpdate(let update):
            renderTool(
                id: update.toolCallId, title: update.title, status: update.status, kind: update.kind,
                locations: update.locations, rawInput: update.rawInput, rawOutput: update.rawOutput,
                content: update.content, clearing: update.nullMembers)
        case .plan(let entries):
            beginSection()
            writeLine(bold("[plan]"))
            for entry in entries {
                writeLine("  - [\(entry.status?.rawValue ?? "pending")] \(entry.content)")
            }
        case .availableCommandsUpdate, .currentModeUpdate, .usageUpdate, .other:
            break
        }
    }

    // MARK: Tool state machine (mirrors renderToolUpdate)

    private func renderTool(
        id: String, title: String?, status: ToolCallStatus?, kind: ToolKind?,
        locations: [ToolCallLocation]?, rawInput: JSONValue?, rawOutput: JSONValue?,
        content: [ToolCallContent]?, clearing nulled: Set<String> = []
    ) {
        let state = toolStates[id] ?? {
            let created = ToolRenderState(id: id)
            toolStates[id] = created
            return created
        }()

        // acpx's `mergeToolTitle` / `mergeToolPayloadState`: a title that is not blank,
        // and each other member that was sent — `null` clearing it.
        if let title, !title.javaScriptTrimmed.isEmpty { state.title = title }
        if status != nil || nulled.contains("status") { state.status = status }
        if kind != nil || nulled.contains("kind") { state.kind = kind }
        if locations != nil || nulled.contains("locations") { state.locations = locations }
        if rawInput != nil || nulled.contains("rawInput") { state.rawInput = rawInput }
        if rawOutput != nil || nulled.contains("rawOutput") { state.rawOutput = rawOutput }
        if content != nil || nulled.contains("content") { state.content = content }

        let isFinal = state.status == .completed || state.status == .failed
        if isFinal {
            let signature = toolSignature(state)
            if signature != state.finalSignature {
                state.finalSignature = signature
                renderFinalToolState(state)
            }
            return
        }

        if state.startedPrinted { return }
        state.startedPrinted = true
        renderStartingToolState(state)
    }

    private func renderStartingToolState(_ state: ToolRenderState) {
        beginSection()
        let title = state.title ?? state.id
        let label = state.status == .pending ? "pending" : "running"
        writeLine("\(bold("[tool]")) \(title) (\(colorStatus(label, state.status)))")
        if let input = ToolText.summarizeInput(state.rawInput) { writeLine("  input: \(input)") }
        if let files = ToolText.formatLocations(state.locations) { writeLine("  files: \(files)") }
    }

    private func renderFinalToolState(_ state: ToolRenderState) {
        beginSection()
        let title = state.title ?? state.id
        let label = state.status == .failed ? "failed" : "completed"
        writeLine("\(bold("[tool]")) \(title) (\(colorStatus(label, state.status)))")
        if let kind = state.kind { writeLine("  kind: \(kind.rawValue)") }
        if let input = ToolText.summarizeInput(state.rawInput) { writeLine("  input: \(input)") }
        if let files = ToolText.formatLocations(state.locations) { writeLine("  files: \(files)") }
        if let output = renderedToolOutput(state) {
            writeLine("  output:")
            writeLine(indentBlock(limitOutputBlock(output), "    "))
        }
    }

    private func renderedToolOutput(_ state: ToolRenderState) -> String? {
        if options.suppressReads, ToolText.isReadLike(title: state.title, kind: state.kind) {
            return SUPPRESSED_READ_OUTPUT
        }
        return ToolText.summarizeOutput(rawOutput: state.rawOutput, content: state.content)
    }

    private func toolSignature(_ state: ToolRenderState) -> String {
        let parts: [String] = [
            state.title ?? "",
            state.status?.rawValue ?? "",
            state.kind?.rawValue ?? "",
            ToolText.summarizeInput(state.rawInput) ?? "",
            ToolText.formatLocations(state.locations) ?? "",
            renderedToolOutput(state) ?? ""
        ]
        return parts.joined(separator: "\u{1F}")
    }

    // MARK: Thought buffering

    private func flushThoughtBuffer() {
        let normalized = normalizeLineEndings(thoughtBuffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let thought = truncate(normalized, MAX_THOUGHT_CHARS)
        thoughtBuffer = ""
        guard !thought.isEmpty else { return }
        beginSection()
        let lines = thought.components(separatedBy: "\n")
        writeLine(dim("[thinking] \(lines[0])"))
        for line in lines.dropFirst() {
            writeLine(dim("           \(line)"))
        }
    }

    // MARK: Low-level writing (mirrors output.ts write/beginSection)

    private func writeAssistantChunk(_ text: String) {
        guard !text.isEmpty else { return }
        write(text)
    }

    private func write(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        out(chunk)
        wroteAny = true
        atLineStart = chunk.hasSuffix("\n")
    }

    private func writeLine(_ line: String) { write(line + "\n") }

    /// Separate a new non-assistant section with a blank line.
    private func beginSection() {
        if !atLineStart { write("\n") }
        if wroteAny { write("\n") }
    }

    // MARK: ANSI

    private func ansi(_ text: String, _ code: String) -> String {
        useColor ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }
    private func bold(_ text: String) -> String { ansi(text, "1") }
    private func dim(_ text: String) -> String { ansi(text, "2") }
    private func colorStatus(_ text: String, _ status: ToolCallStatus?) -> String {
        switch status {
        case .some(.completed): return ansi(text, "32")
        case .some(.failed): return ansi(text, "31")
        default: return ansi(text, "33")
        }
    }
    private func colorStatus(_ status: ClientOperationStatus) -> String {
        switch status {
        case .completed: return ansi(status.rawValue, "32")
        case .failed: return ansi(status.rawValue, "31")
        default: return ansi(status.rawValue, "33")
        }
    }
}

private final class ToolRenderState {
    let id: String
    var title: String?
    var status: ToolCallStatus?
    var kind: ToolKind?
    var locations: [ToolCallLocation]?
    var rawInput: JSONValue?
    var rawOutput: JSONValue?
    var content: [ToolCallContent]?
    var startedPrinted = false
    var finalSignature: String?
    init(id: String) { self.id = id }
}

// MARK: - JSON line (for --json)

func encodeLineJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
}
