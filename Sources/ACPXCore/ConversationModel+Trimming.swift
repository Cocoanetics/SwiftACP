import Foundation
import JSONFoundation

/// acpx's `trimConversationForRuntime`: how much of a conversation a record keeps.
extension ConversationModel {
    static func trimForRuntime(_ record: inout SessionRecord) {
        if record.messages.count > maxRuntimeMessages {
            record.messagesTrimmedSinceRead += record.messages.count - maxRuntimeMessages
            record.messages = Array(record.messages.suffix(maxRuntimeMessages))
        }
        record.messages = record.messages.map(trimMessage)
        if let usage = record.requestTokenUsage, usage.count > maxRuntimeRequestTokenUsage {
            let order = requestUsageOrder(record)
            let kept = Set(usage.keys.sorted { (order($0), $0) < (order($1), $1) }.suffix(maxRuntimeRequestTokenUsage))
            record.requestTokenUsage = usage.filter { kept.contains($0.key) }
            record.requestUsageAddedSinceRead.removeAll { !kept.contains($0) }
        }
    }

    /// Where each `request_token_usage` entry comes in acpx's object, which holds them in
    /// the order it got them and keeps the last of them: those the record was read with,
    /// in their order, then those added since, in theirs
    /// (``SessionRecord/requestUsageAddedSinceRead``). One the model did not add comes
    /// between, by its turn's user message, and first where that is gone.
    static func requestUsageOrder(_ record: SessionRecord) -> (String) -> Int {
        var read: [String: Int] = [:]
        if case .object(let members)? = record.parsedByAcpx?["request_token_usage"] {
            for member in members { read[String(decoding: member.key, as: UTF16.self)] = read.count }
        }
        var turns: [String: Int] = [:]
        for case .user(let user) in record.messages where turns[user.id] == nil { turns[user.id] = turns.count }
        var added: [String: Int] = [:]
        for (index, id) in record.requestUsageAddedSinceRead.enumerated() { added[id] = index }
        let (other, since) = (read.count, read.count + 1 + turns.count)
        return { id in added[id].map { since + $0 } ?? read[id] ?? turns[id].map { other + 1 + $0 } ?? other }
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

    /// `trimRuntimeText`: a text longer than `maxChars` UTF-16 code units — JavaScript's
    /// `length` — cut to its first `maxChars - 3` of them, `...` added. A cut through a
    /// surrogate pair leaves half of it, which a Swift string cannot hold: it becomes
    /// U+FFFD, where acpx keeps the lone surrogate (openclaw/acpx#774).
    static func trimRuntimeText(_ value: String, _ maxChars: Int) -> String {
        let units = value.utf16
        guard units.count > maxChars else { return value }
        return String(decoding: Array(units.prefix(max(0, maxChars - 3))), as: UTF16.self) + "..."
    }
}
