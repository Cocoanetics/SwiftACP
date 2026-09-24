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
        recordPromptSubmission(into: &record, prompt: [.text(prompt)], timestamp: timestamp)
    }

    /// Append a structured prompt (text plus attachments) as a `User` message,
    /// mapping each ACP content block onto the persisted thread schema. Returns the
    /// message id, or nil when no block contributed content.
    ///
    /// Attachment *payloads* are deliberately not persisted: acpx writes an image's
    /// full base64 into the record, which inflates every session file by the size of
    /// the image and then prints it as the history preview. The bytes are already in
    /// the turn's wire log if anyone needs them, so the record keeps the MIME type
    /// and drops the data.
    @discardableResult
    public static func recordPromptSubmission(
        into record: inout SessionRecord, prompt: [ContentBlock], timestamp: String = nowISO()
    ) -> String? {
        let content = prompt.compactMap(userContent)
        guard !content.isEmpty else { return nil }
        let id = nextUserMessageId()
        record.messages.append(.user(SessionUserMessage(id: id, content: content)))
        record.updatedAt = timestamp
        trimForRuntime(&record)
        return id
    }

    /// `contentToUserContent` — one ACP prompt block as persisted user content.
    private static func userContent(_ block: ContentBlock) -> SessionUserContent? {
        switch block {
        case .text(let value):
            return .text(trimRuntimeText(value.text, maxRuntimeAgentTextChars))
        case .image(let image):
            return .image(SessionMessageImage(source: "", size: .null, mimeType: image.mimeType))
        case .audio(let audio):
            return .audio(SessionMessageAudio(source: "", mimeType: audio.mimeType))
        case .resourceLink(let link):
            return .mention(uri: link.uri, content: link.title ?? link.name)
        case .resource(let resource):
            guard let text = resource.resource.text else {
                return .mention(uri: resource.resource.uri, content: resource.resource.uri)
            }
            return .text(trimRuntimeText(text, maxRuntimeAgentTextChars))
        }
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
    /// `cumulative_token_usage` and the turn's `request_token_usage` — acpx's
    /// `recordPromptResponseUsage`, which its prompt turn calls with the id of the user
    /// message that started the turn. Where Claude Code actually carries the breakdown.
    ///
    /// - Parameters:
    ///   - promptMessageId: the turn's user message; the last one on the record when
    ///     omitted, as acpx falls back to `lastUserMessageId`.
    /// - Returns: whether a breakdown was found and recorded.
    @discardableResult
    public static func recordResponseUsage(
        into record: inout SessionRecord, _ usage: PromptUsage, promptMessageId: String? = nil,
        timestamp: String = nowISO()
    ) -> Bool {
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
        guard fields.contains(where: { $0 != nil }) else { return false }
        record.cumulativeTokenUsage = tokens
        if let userId = promptMessageId ?? lastUserMessageId(record) {
            setRequestUsage(tokens, for: userId, in: &record)
        }
        // acpx stamps the conversation and trims it here too, so a usage-only write
        // leaves the record as current as any other update would.
        record.updatedAt = timestamp
        trimForRuntime(&record)
        return true
    }

    // MARK: - Update dispatch (SESSION_UPDATE_HANDLERS)

    private static func applySessionUpdate(into record: inout SessionRecord, update: SessionUpdate) {
        switch update {
        case .userMessageChunk(let block):
            // Recorded as a prompt's block is (`appendUserMessageChunk`).
            if let content = userContent(block) {
                record.messages.append(.user(SessionUserMessage(id: nextUserMessageId(), content: [content])))
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
        case .availableCommandsUpdate(let commands):
            var acpx = record.acpx ?? SessionAcpxState()
            acpx.availableCommands = commands.compactMap(recordedCommand)
            record.acpx = acpx
        case .other(let kind, let payload):
            applyOtherUpdate(kind, payload, into: &record)
        case .plan:
            // No handler in acpx either.
            break
        }
    }

    /// An advertised command as acpx records it (`normalizeAvailableCommand`): its name
    /// and description trimmed, an empty description left out, and whether it takes
    /// input. One acpx's ACP SDK skips — a command without a description, as a bare
    /// name is — or whose name is blank, is not recorded.
    private static func recordedCommand(_ command: AvailableCommand) -> SessionAcpxState.AvailableCommand? {
        let name = command.name.javaScriptTrimmed
        guard let description = command.description?.javaScriptTrimmed, !name.isEmpty else { return nil }
        // The SDK reads an input other than `{ hint: string }` as none.
        var hasInput = false
        if case .object(let input)? = command.input, case .string? = input["hint"] { hasInput = true }
        return .detailed(.init(name: name, description: description.isEmpty ? nil : description, hasInput: hasInput))
    }

    /// The updates decoded as ``SessionUpdate/other(kind:payload:)`` that acpx records:
    /// the conversation's title (`session_info_update`, `applySessionInfoUpdate`) and
    /// the session's config options (`config_option_update`, `applyConfigOptionsModelState`).
    private static func applyOtherUpdate(_ kind: String, _ payload: JSONValue, into record: inout SessionRecord) {
        guard case .object(let update) = payload else { return }
        switch kind {
        case "session_info_update":
            // A title the update carries is taken: a string as the title, anything else as
            // none — acpx's ACP SDK reads what is no string as undefined, which acpx
            // records as `null`. Its `updatedAt` is stamped over with the update's time.
            if let title = update["title"] {
                if case .string(let text) = title { record.title = text } else { record.title = nil }
            }
        case "config_option_update":
            var acpx = record.acpx ?? SessionAcpxState()
            var options: [JSONValue] = []
            if case .array(let reported)? = update["configOptions"] { options = reported }
            ModelSupport.applyConfigOptionsModelState(options, to: &acpx)
            record.acpx = acpx
        default:
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
                setRequestUsage(usage, for: userId, in: &record)
            }
        }
        if let cost = usageCost(from: update) {
            record.cumulativeCost = cost
        }
    }

    /// `request_token_usage[id] = usage`, as acpx's object takes it: an entry it lacks
    /// comes last (``SessionRecord/requestUsageAddedSinceRead``), one it has keeps its place.
    private static func setRequestUsage(_ usage: SessionTokenUsage, for id: String, in record: inout SessionRecord) {
        var requests = record.requestTokenUsage ?? [:]
        if requests.updateValue(usage, forKey: id) == nil { record.requestUsageAddedSinceRead.append(id) }
        record.requestTokenUsage = requests
    }

    /// The token breakdown under `_meta.usage`, accepting both snake_case and
    /// camelCase keys (as acpx's `numberField` does). Returns nil when the agent
    /// sent no breakdown (e.g. Codex, which sends only `used` / `size`).
    private static func tokenUsage(from update: UsageUpdate) -> SessionTokenUsage? {
        // `_meta.usage` when the adapter nests it there, else the update itself — acpx's
        // `usageToTokenUsage` (`asRecord(usageMeta) ?? updateRecord`), so an adapter that
        // reports the breakdown at the top level is captured too. A bare `used`/`size`
        // update still yields nothing: none of those keys is a token field.
        let source: [String: JSONValue]
        if case .object(let meta)? = update.meta, case .object(let nested)? = meta["usage"] {
            source = nested
        } else if case .object(let body)? = update.raw {
            source = body
        } else {
            return nil
        }
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
    /// acpx's `numberField`: the first spelling whose value is a finite, non-negative
    /// number. A present-but-unusable value (negative, NaN) is skipped rather than
    /// taken, so a later spelling still gets its chance.
    private static func number(_ object: [String: JSONValue], _ keys: [String]) -> Double? {
        for key in keys {
            let candidate: Double?
            switch object[key] {
            case .integer(let value): candidate = Double(value)
            case .double(let value): candidate = value
            default: candidate = nil
            }
            if let candidate, candidate.isFinite, candidate >= 0 { return candidate }
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
            agent.content.append(.thinking(text: text, signature: .null))
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
            // No `status` in this patch means "unchanged", not "not an error" — a
            // recorded failure must survive a later output-only update (acpx:
            // `is_error: status === undefined ? undefined : statusIndicatesError(status)`).
            let isError = fields.status.map { statusIndicatesError($0.rawValue) }
            // `JSONValue?.none`, not a bare `nil`: `JSONValue` is `ExpressibleByNilLiteral`,
            // so `nil` here unifies as `JSONValue.null` and a status-only patch would
            // overwrite recorded output with null instead of keeping it.
            let content: JSONValue? =
                fields.hasRawOutput ? toToolResultContent(fields.rawOutput) : JSONValue?.none
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
        _ agent: inout SessionAgentMessage, id: String, toolName: String, isError: Bool?,
        content: JSONValue?, output: JSONValue?
    ) {
        let existing = agent.toolResults[id]
        agent.toolResults[id] = SessionToolResult(
            toolUseId: id,
            toolName: toolName,
            isError: isError ?? existing?.isError ?? false,
            content: content ?? existing?.content ?? .object(["Text": .string("")]),
            output: output ?? existing?.output)
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
        return trimRuntimeText(javaScriptJSON(value) ?? "{}", maxRuntimeToolIOChars)
    }

    /// `toToolResultContent` — a tool's output as `{ "Text": <trimmed string> }`.
    private static func toToolResultContent(_ value: JSONValue?) -> JSONValue {
        guard let value, value != .null else { return .object(["Text": .string("")]) }
        if case .string(let text) = value {
            return .object(["Text": .string(trimRuntimeText(text, maxRuntimeToolIOChars))])
        }
        let json = javaScriptJSON(value) ?? "[Unserializable value]"
        return .object(["Text": .string(trimRuntimeText(json, maxRuntimeToolIOChars))])
    }

    /// `JSON.stringify(value)`, with its escapes and number forms. The members come
    /// sorted: the order the agent sent them in is gone once the value is a `JSONValue`.
    private static func javaScriptJSON(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { WireJSON(parsing: $0) }?.stringified
    }
}
