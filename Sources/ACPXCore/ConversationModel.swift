import Foundation
import JSONFoundation
import SwiftACP

/// Builds a session's persisted conversation (`messages` + `tool_results`) from
/// streamed ACP updates, faithfully porting acpx 0.11.0's `conversation-model.ts`.
///
/// Each prompt turn calls ``recordPromptSubmission(into:prompt:timestamp:)`` once,
/// then ``recordSessionUpdate(into:notification:timestamp:)`` for every
/// `session/update`. The model coalesces text/thought chunks, maintains one
/// `ToolUse` block per tool-call id (updating its input/status across the call's
/// lifecycle), and accumulates each call's output into `tool_results` — exactly
/// the shape the upstream node CLI writes.
public enum ConversationModel {
    static let maxRuntimeMessages = 200
    static let maxRuntimeAgentTextChars = 8000
    static let maxRuntimeThinkingChars = 4000
    static let maxRuntimeToolIOChars = 4000
    static let maxRuntimeRequestTokenUsage = 100

    // MARK: - Public entry points

    /// Append the user's prompt as a `User` message. Returns its id (nil if empty).
    @discardableResult
    public static func recordPromptSubmission(
        into record: inout SessionRecord, prompt: String, timestamp: String = nowISO()
    ) -> String? {
        let id = nextUserMessageId()
        let text = trimRuntimeText(prompt, maxRuntimeAgentTextChars)
        record.messages.append(.user(SessionUserMessage(id: id, content: [.text(text)])))
        record.updatedAt = timestamp
        trimForRuntime(&record)
        return id
    }

    /// Apply one streamed `session/update` to the conversation.
    public static func recordSessionUpdate(
        into record: inout SessionRecord, notification: SessionNotification,
        timestamp: String = nowISO()
    ) {
        applySessionUpdate(into: &record, update: notification.update)
        record.updatedAt = timestamp
        trimForRuntime(&record)
    }

    /// Record the token breakdown an agent reports on the *prompt response* into
    /// `cumulative_token_usage` (+ the turn's `request_token_usage`).
    ///
    /// This is where Claude Code actually carries the breakdown — acpx looks only
    /// at `usage_update._meta.usage` and so misses it; capturing it here records
    /// usage that upstream acpx drops.
    public static func recordResponseUsage(into record: inout SessionRecord, _ usage: PromptUsage) {
        var tokens = SessionTokenUsage()
        tokens.inputTokens = usage.inputTokens
        tokens.outputTokens = usage.outputTokens
        tokens.cacheReadInputTokens = usage.cachedReadTokens
        tokens.cacheCreationInputTokens = usage.cachedWriteTokens
        tokens.thoughtTokens = usage.thoughtTokens
        tokens.totalTokens = usage.totalTokens
        let fields = [
            tokens.inputTokens, tokens.outputTokens, tokens.cacheReadInputTokens,
            tokens.cacheCreationInputTokens, tokens.thoughtTokens, tokens.totalTokens
        ]
        guard fields.contains(where: { $0 != nil }) else { return }
        record.cumulativeTokenUsage = tokens
        if let userId = lastUserMessageId(record) {
            var requests = record.requestTokenUsage ?? [:]
            requests[userId] = tokens
            record.requestTokenUsage = requests
        }
    }

    // MARK: - Update dispatch (SESSION_UPDATE_HANDLERS)

    private static func applySessionUpdate(into record: inout SessionRecord, update: SessionUpdate) {
        switch update {
        case .userMessageChunk(let block):
            if let text = extractText(block) {
                record.messages.append(
                    .user(SessionUserMessage(id: nextUserMessageId(), content: [.text(text)])))
            }
        case .agentMessageChunk(let block):
            if let text = extractText(block) {
                withCurrentAgentMessage(&record) { appendAgentText(&$0, text) }
            }
        case .agentThoughtChunk(let block):
            if let text = extractText(block) {
                withCurrentAgentMessage(&record) { appendAgentThinking(&$0, text) }
            }
        case .toolCall(let call):
            withCurrentAgentMessage(&record) { applyToolCall(&$0, fields: ToolFields(call)) }
        case .toolCallUpdate(let update):
            withCurrentAgentMessage(&record) { applyToolCall(&$0, fields: ToolFields(update)) }
        case .currentModeUpdate(let modeId):
            var acpx = record.acpx ?? SessionAcpxState()
            acpx.currentModeId = modeId
            record.acpx = acpx
        case .usageUpdate(let usage):
            applyUsageUpdate(into: &record, usage)
        case .plan, .availableCommandsUpdate, .other:
            // `plan` has no handler in acpx either; available-commands /
            // session-info / config-option updates are not modelled here.
            break
        }
    }

    // MARK: - Usage updates (cost + _meta.usage token breakdown)

    /// Record an agent `usage_update`: the `cost` into `cumulative_cost`, and the
    /// `_meta.usage` token breakdown into `cumulative_token_usage` (+ the current
    /// turn's `request_token_usage`). Faithful to acpx's `applyUsageUpdate` —
    /// `used` / `size` are surfaced on the live stream, not persisted.
    private static func applyUsageUpdate(into record: inout SessionRecord, _ update: UsageUpdate) {
        if let usage = tokenUsage(from: update) {
            record.cumulativeTokenUsage = usage
            if let userId = lastUserMessageId(record) {
                var requests = record.requestTokenUsage ?? [:]
                requests[userId] = usage
                record.requestTokenUsage = requests
            }
        }
        if let cost = usageCost(from: update) {
            record.cumulativeCost = cost
        }
    }

    /// The token breakdown under `_meta.usage`, accepting both snake_case and
    /// camelCase keys (as acpx's `numberField` does). Returns nil when the agent
    /// sent no breakdown (e.g. Codex, which sends only `used` / `size`).
    private static func tokenUsage(from update: UsageUpdate) -> SessionTokenUsage? {
        guard case .object(let meta)? = update.meta, case .object(let source)? = meta["usage"]
        else { return nil }
        var usage = SessionTokenUsage()
        usage.inputTokens = number(source, ["input_tokens", "inputTokens"])
        usage.outputTokens = number(source, ["output_tokens", "outputTokens"])
        usage.cacheCreationInputTokens = number(
            source, ["cache_creation_input_tokens", "cacheCreationInputTokens", "cachedWriteTokens"])
        usage.cacheReadInputTokens = number(
            source, ["cache_read_input_tokens", "cacheReadInputTokens", "cachedReadTokens"])
        usage.thoughtTokens = number(source, ["thought_tokens", "thoughtTokens"])
        usage.totalTokens = number(source, ["total_tokens", "totalTokens"])
        let fields = [
            usage.inputTokens, usage.outputTokens, usage.cacheCreationInputTokens,
            usage.cacheReadInputTokens, usage.thoughtTokens, usage.totalTokens
        ]
        return fields.contains { $0 != nil } ? usage : nil
    }

    private static func usageCost(from update: UsageUpdate) -> SessionUsageCost? {
        guard let cost = update.cost, cost.amount != nil || cost.currency != nil else { return nil }
        return SessionUsageCost(amount: cost.amount, currency: cost.currency)
    }

    /// First numeric value among `keys` in `object`.
    private static func number(_ object: [String: JSONValue], _ keys: [String]) -> Double? {
        for key in keys {
            switch object[key] {
            case .integer(let value): return Double(value)
            case .double(let value): return value
            default: continue
            }
        }
        return nil
    }

    private static func lastUserMessageId(_ record: SessionRecord) -> String? {
        for message in record.messages.reversed() {
            if case .user(let user) = message { return user.id }
        }
        return nil
    }

    // MARK: - Agent message accumulation

    /// Mutate the turn's agent message — the last message if it's already an
    /// `Agent`, otherwise a fresh one appended to the conversation.
    private static func withCurrentAgentMessage(
        _ record: inout SessionRecord, _ body: (inout SessionAgentMessage) -> Void
    ) {
        if case .agent(var agent) = record.messages.last {
            body(&agent)
            record.messages[record.messages.count - 1] = .agent(agent)
        } else {
            var agent = SessionAgentMessage(content: [], toolResults: [:])
            body(&agent)
            record.messages.append(.agent(agent))
        }
    }

    private static func appendAgentText(_ agent: inout SessionAgentMessage, _ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if case .text(let existing) = agent.content.last {
            agent.content[agent.content.count - 1] =
                .text(trimRuntimeText(existing + text, maxRuntimeAgentTextChars))
        } else {
            agent.content.append(.text(text))
        }
    }

    private static func appendAgentThinking(_ agent: inout SessionAgentMessage, _ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if case .thinking(let existing, let signature) = agent.content.last {
            agent.content[agent.content.count - 1] =
                .thinking(
                    text: trimRuntimeText(existing + text, maxRuntimeThinkingChars),
                    signature: signature)
        } else {
            agent.content.append(.thinking(text: text, signature: nil))
        }
    }

    // MARK: - Tool calls → ToolUse content + tool_results

    /// The subset of fields acpx reads from a `tool_call` / `tool_call_update`,
    /// with presence flags (it distinguishes "field absent" from "field present").
    private struct ToolFields {
        let id: String
        let title: String?
        let kind: ToolKind?
        let status: ToolCallStatus?
        let hasRawInput: Bool
        let rawInput: JSONValue?
        let hasRawOutput: Bool
        let rawOutput: JSONValue?

        init(_ call: ToolCall) {
            id = call.toolCallId
            title = call.title
            kind = call.kind
            status = call.status
            hasRawInput = call.rawInput != nil
            rawInput = call.rawInput
            hasRawOutput = call.rawOutput != nil
            rawOutput = call.rawOutput
        }

        init(_ update: ToolCallUpdate) {
            id = update.toolCallId
            title = update.title
            kind = update.kind
            status = update.status
            hasRawInput = update.rawInput != nil
            rawInput = update.rawInput
            hasRawOutput = update.rawOutput != nil
            rawOutput = update.rawOutput
        }

        var hasResultPatch: Bool {
            hasRawOutput || status != nil || title != nil || kind != nil
        }
    }

    private static func applyToolCall(_ agent: inout SessionAgentMessage, fields: ToolFields) {
        let index = ensureToolUseIndex(&agent, id: fields.id)
        guard case .toolUse(var tool) = agent.content[index] else { return }

        // Identity: prefer the title, else fall back to the kind.
        if let title = trimmedString(fields.title) {
            tool.name = title
        }
        if let kind = trimmedString(fields.kind?.rawValue), tool.name.isEmpty || tool.name == "tool_call" {
            tool.name = kind
        }
        // Input.
        if fields.hasRawInput {
            tool.input = fields.rawInput
            tool.rawInput = toRawInput(fields.rawInput)
        }
        // Status → whether the input is complete.
        if let status = fields.status {
            tool.isInputComplete = statusIndicatesComplete(status.rawValue)
        }
        agent.content[index] = .toolUse(tool)

        // Result (output) goes into tool_results, keyed by id.
        if fields.hasResultPatch {
            let isError = statusIndicatesError(fields.status?.rawValue)
            let content: JSONValue? =
                fields.hasRawOutput ? toToolResultContent(fields.rawOutput) : nil
            upsertToolResult(
                &agent, id: fields.id, toolName: tool.name, isError: isError,
                content: content, output: fields.hasRawOutput ? fields.rawOutput : nil)
        }
    }

    /// Index of the `ToolUse` block with `id`, creating one if absent.
    private static func ensureToolUseIndex(_ agent: inout SessionAgentMessage, id: String) -> Int {
        for (index, content) in agent.content.enumerated() {
            if case .toolUse(let tool) = content, tool.id == id { return index }
        }
        agent.content.append(
            .toolUse(
                SessionToolUse(
                    id: id, name: "tool_call", rawInput: "{}", input: .object([:]),
                    isInputComplete: false, thoughtSignature: .null)))
        return agent.content.count - 1
    }

    private static func upsertToolResult(
        _ agent: inout SessionAgentMessage, id: String, toolName: String, isError: Bool,
        content: JSONValue?, output: JSONValue?
    ) {
        let existing = agent.toolResults[id]
        agent.toolResults[id] = SessionToolResult(
            toolUseId: id,
            toolName: toolName,
            isError: isError,
            content: content ?? existing?.content ?? .object(["Text": .string("")]),
            output: output ?? existing?.output)
    }

    // MARK: - Trimming (trimConversationForRuntime)

    private static func trimForRuntime(_ record: inout SessionRecord) {
        if record.messages.count > maxRuntimeMessages {
            record.messages = Array(record.messages.suffix(maxRuntimeMessages))
        }
        record.messages = record.messages.map(trimMessage)
        if let usage = record.requestTokenUsage, usage.count > maxRuntimeRequestTokenUsage {
            // Keep the most recent entries (insertion order isn't preserved by a
            // dictionary, so this just bounds growth, matching acpx's intent).
            record.requestTokenUsage = Dictionary(
                usage.suffix(maxRuntimeRequestTokenUsage)) { _, new in new }
        }
    }

    private static func trimMessage(_ message: SessionMessage) -> SessionMessage {
        switch message {
        case .user(var user):
            user.content = user.content.map { content in
                if case .text(let text) = content {
                    return .text(trimRuntimeText(text, maxRuntimeAgentTextChars))
                }
                return content
            }
            return .user(user)
        case .agent(var agent):
            agent.content = agent.content.map(trimAgentContent)
            agent.toolResults = agent.toolResults.mapValues(trimToolResult)
            return .agent(agent)
        case .resume:
            return message
        }
    }

    private static func trimAgentContent(_ content: SessionAgentContent) -> SessionAgentContent {
        switch content {
        case .text(let text):
            return .text(trimRuntimeText(text, maxRuntimeAgentTextChars))
        case .thinking(let text, let signature):
            return .thinking(text: trimRuntimeText(text, maxRuntimeThinkingChars), signature: signature)
        case .toolUse(var tool):
            tool.rawInput = trimRuntimeText(tool.rawInput, maxRuntimeToolIOChars)
            return .toolUse(tool)
        default:
            return content
        }
    }

    private static func trimToolResult(_ result: SessionToolResult) -> SessionToolResult {
        var result = result
        if case .object(var object) = result.content, case .string(let text)? = object["Text"] {
            object["Text"] = .string(trimRuntimeText(text, maxRuntimeToolIOChars))
            result.content = .object(object)
        }
        if case .string(let output)? = result.output {
            result.output = .string(trimRuntimeText(output, maxRuntimeToolIOChars))
        }
        return result
    }

    // MARK: - Helpers

    private static func nextUserMessageId() -> String { UUID().uuidString.lowercased() }

    /// `extractText` — the text an ACP content block contributes to a message.
    private static func extractText(_ block: ContentBlock) -> String? {
        switch block {
        case .text(let text): return text.text
        case .resourceLink(let link): return link.title ?? link.name
        case .audio(let audio): return "[audio] \(audio.mimeType)"
        default: return block.text
        }
    }

    private static func trimmedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func statusIndicatesComplete(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        return ["complete", "done", "success", "failed", "error", "cancel"].contains {
            status.contains($0)
        }
    }

    private static func statusIndicatesError(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        return status.contains("fail") || status.contains("error")
    }

    /// `toRawInput` — a tool's input as a trimmed JSON string.
    private static func toRawInput(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "{}" }
        if case .string(let text) = value { return trimRuntimeText(text, maxRuntimeToolIOChars) }
        let json = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return trimRuntimeText(json, maxRuntimeToolIOChars)
    }

    /// `toToolResultContent` — a tool's output as `{ "Text": <trimmed string> }`.
    private static func toToolResultContent(_ value: JSONValue?) -> JSONValue {
        guard let value, value != .null else { return .object(["Text": .string("")]) }
        if case .string(let text) = value {
            return .object(["Text": .string(trimRuntimeText(text, maxRuntimeToolIOChars))])
        }
        let json =
            (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
            ?? "[Unserializable value]"
        return .object(["Text": .string(trimRuntimeText(json, maxRuntimeToolIOChars))])
    }

    /// `trimRuntimeText` — truncate to `maxChars`, appending an ellipsis.
    static func trimRuntimeText(_ value: String, _ maxChars: Int) -> String {
        guard value.count > maxChars else { return value }
        return String(value.prefix(max(0, maxChars - 3))) + "..."
    }
}
