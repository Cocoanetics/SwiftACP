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
        }
    }

    /// Where each `request_token_usage` entry comes in the order acpx added them, which it
    /// keeps the last of: those the record was read with, in their order, then one a turn
    /// since, under the turn's user message id — any whose message is gone before those
    /// whose message is not.
    private static func requestUsageOrder(_ record: SessionRecord) -> (String) -> Int {
        var read: [String: Int] = [:]
        if case .object(let members)? = record.parsedByAcpx?["request_token_usage"] {
            for member in members { read[String(decoding: member.key, as: UTF16.self)] = read.count }
        }
        var turns: [String: Int] = [:]
        for case .user(let user) in record.messages where turns[user.id] == nil { turns[user.id] = turns.count }
        let (readCount, gone) = (read.count, read.count)
        return { id in read[id] ?? turns[id].map { readCount + 1 + $0 } ?? gone }
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

    /// `trimRuntimeText` — truncate to `maxChars`, appending an ellipsis.
    static func trimRuntimeText(_ value: String, _ maxChars: Int) -> String {
        guard value.count > maxChars else { return value }
        return String(value.prefix(max(0, maxChars - 3))) + "..."
    }
}
