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
    /// An image or an audio clip is recorded with its data and MIME type, as acpx 0.19.3
    /// records it (openclaw/acpx#766). History previews name it by its type instead
    /// (``SessionUserContent/previewText``).
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
            return .image(SessionMessageImage(source: image.data, mimeType: .value(image.mimeType), size: .null))
        case .audio(let audio):
            return .audio(SessionMessageAudio(source: audio.data, mimeType: audio.mimeType))
        case .resourceLink(let link):
            return .mention(uri: link.uri, content: link.title ?? link.name)
        case .resource(let resource):
            guard let text = resource.resource.text else {
                return .mention(uri: resource.resource.uri, content: resource.resource.uri)
            }
            return .text(trimRuntimeText(text, maxRuntimeAgentTextChars))
        }
    }

    /// Apply one streamed `session/update` to the conversation. Returns whether it was
    /// applied: an update acpx's SDK refuses (``SwiftACP/SessionUpdate/reachesACPX``) never
    /// reaches acpx's handler, so it leaves the record as it was, not even stamped.
    @discardableResult
    public static func recordSessionUpdate(
        into record: inout SessionRecord, notification: SessionNotification,
        timestamp: String = nowISO()
    ) -> Bool {
        guard notification.update.reachesACPX else { return false }
        applySessionUpdate(into: &record, update: notification.update, raw: notification.rawUpdate)
        record.updatedAt = timestamp
        trimForRuntime(&record)
        return true
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

    /// `raw`: the update as the agent wrote it, which a tool's payloads are recorded in the order of.
    private static func applySessionUpdate(into record: inout SessionRecord, update: SessionUpdate, raw: WireJSON?) {
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
            withCurrentAgentMessage(&record) { applyToolCall(&$0, fields: ToolFields(call, raw: raw)) }
        case .toolCallUpdate(let update):
            withCurrentAgentMessage(&record) { applyToolCall(&$0, fields: ToolFields(update, raw: raw)) }
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
            // The options as acpx's SDK hands them on (``ConfigOptionSchema``).
            guard let options = ConfigOptionSchema.options(of: payload) else { return }
            var acpx = record.acpx ?? SessionAcpxState()
            ModelSupport.applyConfigOptionsModelState(options, to: &acpx)
            // In the order the SDK built them (#175).
            acpx.configOptionsOrder = ConfigOptionSchema.ordered(options)
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
    ///
    /// acpx's `usageToTokenUsage` falls back to the update itself, but its SDK has stripped
    /// every key of it but `used`, `size`, `cost` and `_meta` by then, so counts reported
    /// there are never read (``SwiftACP/UsageUpdate/acpxTokenUsage``).
    private static func tokenUsage(from update: UsageUpdate) -> SessionTokenUsage? {
        guard let source = update.acpxTokenUsage else { return nil }
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

    /// acpx's `usageCost`, on the cost its SDK passes on: the amount if it is finite and not
    /// negative, the currency if it is not blank, and no cost when neither is.
    private static func usageCost(from update: UsageUpdate) -> SessionUsageCost? {
        guard let (amount, currency) = update.acpxCost else { return nil }
        let cost = SessionUsageCost(
            amount: amount.isFinite && amount >= 0 ? amount : nil,
            currency: currency.javaScriptTrimmed.isEmpty ? nil : currency)
        return cost.amount != nil || cost.currency != nil ? cost : nil
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
            case .unsignedInteger(let value): candidate = Double(value)
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
}
