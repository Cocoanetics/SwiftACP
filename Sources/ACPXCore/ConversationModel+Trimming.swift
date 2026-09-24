import Foundation
import JSONFoundation

/// acpx's `trimConversationForRuntime`: how much of a conversation a record keeps.
extension ConversationModel {
    static func trimForRuntime(_ record: inout SessionRecord) {
        if record.messages.count > maxRuntimeMessages {
            record.messages = Array(record.messages.suffix(maxRuntimeMessages))
        }
        record.messages = record.messages.map(trimMessage)
        if let usage = record.requestTokenUsage, usage.count > maxRuntimeRequestTokenUsage {
            // acpx keeps the entries it added last: one a turn, under the turn's user
            // message id — so the oldest, whose message is gone, go first.
            var position: [String: Int] = [:]
            for case .user(let user) in record.messages { position[user.id] = position[user.id] ?? position.count }
            let kept = Set(usage.keys.sorted { (position[$0] ?? -1, $0) < (position[$1] ?? -1, $1) }
                .suffix(maxRuntimeRequestTokenUsage))
            record.requestTokenUsage = usage.filter { kept.contains($0.key) }
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

    /// `trimRuntimeText` — truncate to `maxChars`, appending an ellipsis.
    static func trimRuntimeText(_ value: String, _ maxChars: Int) -> String {
        guard value.count > maxChars else { return value }
        return String(value.prefix(max(0, maxChars - 3))) + "..."
    }
}
