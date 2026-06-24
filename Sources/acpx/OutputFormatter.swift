import Foundation
import JSONFoundation
import SwiftACP

// A faithful port of acpx's `src/cli/output/output.ts` text + quiet rendering:
// a per-tool state machine that prints each tool once on start and once on its
// final status (deduped by signature), structured `[tool]/[plan]/[thinking]/
// [done]` sections, and read-output suppression. The whole transcript goes to
// stdout in text mode; quiet mode emits only the assistant's final text.

// MARK: - Constants (match output.ts)

private let MAX_THOUGHT_CHARS = 900
private let MAX_OUTPUT_CHARS = 2000
private let MAX_OUTPUT_LINES = 28
let SUPPRESSED_READ_OUTPUT = "[read output suppressed]"

// MARK: - Output format

enum OutputFormat: Sendable { case text, json, quiet }

struct RenderOptions: Sendable {
    var format: OutputFormat = .text
    /// Replace read-like tools' output with `[read output suppressed]`.
    var suppressReads = false
}

/// Renders a turn's `SessionUpdate`s. One instance per turn; access is serial
/// (the run loop invokes it from a single task), guarded for `@Sendable` use.
final class OutputRenderer: @unchecked Sendable {
    private let options: RenderOptions
    private let lock = NSLock()
    private let useColor = isatty(fileno(stdout)) != 0

    // Text-mode state
    private var toolStates: [String: ToolRenderState] = [:]
    private var thoughtBuffer = ""
    private var wroteAny = false
    private var atLineStart = true

    // Quiet-mode buffer
    private var quietChunks: [String] = []

    init(options: RenderOptions) {
        self.options = options
    }

    // MARK: Entry points

    func render(_ update: SessionUpdate) {
        lock.lock()
        defer { lock.unlock() }
        switch options.format {
        case .json: Console.out(encodeLineJSON(update) + "\n")
        case .quiet: renderQuiet(update)
        case .text: renderText(update)
        }
    }

    func finish(stopReason: StopReason) {
        lock.lock()
        defer { lock.unlock() }
        switch options.format {
        case .json:
            Console.out(encodeLineJSON(["stopReason": stopReason.rawValue]) + "\n")
        case .quiet:
            flushQuiet()
        case .text:
            flushThoughtBuffer()
            beginSection()
            writeLine(dim("[done] \(stopReason.rawValue)"))
            if !atLineStart { write("\n") }
        }
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

    /// Render a turn failure as `[error] <code>: <message>` (text mode only).
    /// Mirrors acpx's `onError`, which the wire-driven formatter emits on a
    /// JSON-RPC error response. The raw message is also surfaced on stderr by the
    /// command's `CLIError` handler.
    func renderError(code: String, _ message: String, acpCode: Int? = nil, detailCode: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard options.format == .text else { return }
        flushThoughtBuffer()
        beginSection()
        writeLine(ansi("[error] \(code): \(message)", "31"))
        // The formatter renders the wire (acp-origin) error.
        for hint in remediationHints(
            code: code, origin: "acp", detailCode: detailCode, message: message, acpCode: acpCode) {
            writeLine(dim(hint))
        }
    }

    // MARK: Quiet mode

    private func renderQuiet(_ update: SessionUpdate) {
        if case .agentMessageChunk(let block) = update, let text = block.text {
            quietChunks.append(text)
        }
    }

    private func flushQuiet() {
        let text = quietChunks.joined()
        Console.out(text.hasSuffix("\n") ? text : text + "\n")
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
                content: update.content)
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
        content: [ToolCallContent]?
    ) {
        let state = toolStates[id] ?? {
            let created = ToolRenderState(id: id)
            toolStates[id] = created
            return created
        }()

        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { state.title = title }
        if let status { state.status = status }
        if let kind { state.kind = kind }
        if let locations { state.locations = locations }
        if let rawInput { state.rawInput = rawInput }
        if let rawOutput { state.rawOutput = rawOutput }
        if let content { state.content = content }

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
        Console.out(chunk)
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

// MARK: - Block limiting (limitOutputBlock)

private func limitOutputBlock(_ value: String) -> String {
    let normalized = normalizeLineEndings(value).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return "" }
    var lines = normalized.components(separatedBy: "\n")
    let hidden = lines.count - MAX_OUTPUT_LINES
    if hidden > 0 {
        lines = Array(lines.prefix(MAX_OUTPUT_LINES))
    }
    var result = lines.joined(separator: "\n")
    if hidden > 0 { result += "\n... (\(hidden) more lines)" }
    if result.count > MAX_OUTPUT_CHARS {
        result = String(result.prefix(MAX_OUTPUT_CHARS - 3)) + "..."
    }
    return result
}

private func indentBlock(_ value: String, _ prefix: String) -> String {
    value.components(separatedBy: "\n").map { prefix + $0 }.joined(separator: "\n")
}

private func normalizeLineEndings(_ value: String) -> String {
    value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

private func truncate(_ value: String, _ maxChars: Int) -> String {
    if value.count <= maxChars { return value }
    if maxChars <= 3 { return String(value.prefix(maxChars)) }
    return String(value.prefix(maxChars - 3)) + "..."
}

// MARK: - Error remediation hints (getTextErrorRemediationHints)

/// Port of acpx's `getTextErrorRemediationHints`: an `[error]` line may be
/// followed by `hint:` lines tailored to the failure. The message-pattern rules
/// are what turn errors reach today; the `TIMEOUT`/`NO_SESSION`/`AUTH_REQUIRED`
/// branches mirror acpx for when those classes are routed through the formatter.
func remediationHints(code: String, origin: String?, detailCode: String?, message: String, acpCode: Int?)
    -> [String] {
    let lower = message.lowercased()

    if detailCode == "AUTH_REQUIRED" { return [authRequiredHint] }
    if code == "TIMEOUT" {
        return [
            "hint: increase `--timeout <seconds>` for long-running prompts, or check whether "
                + "the agent/provider is stalled."
        ]
    }
    if code == "NO_SESSION" { return noSessionHints(lower) }

    // First matching message-pattern rule wins (TEXT_ERROR_HINT_RULES order).
    if lower.contains("does not support session/resume") || lower.contains("does not support session/load") {
        return [
            "hint: this adapter cannot resume saved ACP sessions; create a fresh one with "
                + "`acpx <agent> sessions new` instead of reusing `--resume-session`."
        ]
    }
    if lower.contains("failed to resume acp session") || lower.contains("session/resume")
        || lower.contains("session/load") {
        return [
            "hint: rerun with `--verbose` to capture the ACP load failure details.",
            "hint: if you do not need the old backend session, start a fresh one with "
                + "`acpx <agent> sessions new` and retry."
        ]
    }
    if message.range(of: #"\b429\b"#, options: .regularExpression) != nil
        || lower.contains("rate limit") || lower.contains("quota exceeded") {
        return [
            "hint: the provider appears rate-limited; retry later, switch model, or check "
                + "provider quota/billing."
        ]
    }
    if lower.contains("model not found") || lower.contains("unknown model")
        || lower.contains("invalid model") {
        return [
            "hint: check the configured model name for this agent, then retry with "
                + "`--model <model>` or `sessions set-model <model>`."
        ]
    }
    if lower.contains("session/set_mode") || lower.contains("session/set_model")
        || lower.contains("session/set_config_option") {
        return ["hint: rerun with `--verbose` to capture the ACP method/error details before retrying."]
    }
    // isRuntimeAcpProtocolError: acp-origin RUNTIME with a protocol-level code.
    // Origin-gated, so it fires for the formatter (wire, acp origin) but not for
    // the CLI's stderr handler (non-acp origin).
    if origin == "acp", code == "RUNTIME",
        acpCode == -32602 || acpCode == -32603 || lower.contains("internal error") {
        return ["hint: rerun with `--verbose` to capture the underlying ACP error details."]
    }
    return []
}

private func noSessionHints(_ lower: String) -> [String] {
    if lower.contains("create one:") { return [] }
    return [
        "hint: the saved ACP session is missing or stale; start a fresh session with "
            + "`acpx <agent> sessions new`, then retry."
    ]
}

/// acpx's `renderAuthRequiredHint` additionally names the `auth.<methodId>` keys
/// parsed from the error; that method-id extraction is not ported, so its
/// zero-methods (generic) form is used.
private let authRequiredHint =
    "hint: run `acpx config show` to locate the active config, then add the required "
        + "credential under `auth` and retry."

// MARK: - JSON line (for --json)

func encodeLineJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
}
