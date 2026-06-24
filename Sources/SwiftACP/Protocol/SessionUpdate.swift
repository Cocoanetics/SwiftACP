import Foundation
import JSONFoundation

/// A `session/update` notification: the channel the agent uses to stream
/// everything that happens during a turn — message chunks, tool calls, plans.
public struct SessionNotification: Codable, Sendable {
    public var sessionId: SessionId
    public var update: SessionUpdate

    public init(sessionId: SessionId, update: SessionUpdate) {
        self.sessionId = sessionId
        self.update = update
    }
}

/// One streamed event within a turn, tagged by `sessionUpdate`.
/// https://agentclientprotocol.com/protocol/v1/prompt-turn
public enum SessionUpdate: Codable, Sendable {
    case agentMessageChunk(ContentBlock)
    case agentThoughtChunk(ContentBlock)
    case userMessageChunk(ContentBlock)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    case plan([PlanEntry])
    case availableCommandsUpdate([AvailableCommand])
    case currentModeUpdate(modeId: String)
    case usageUpdate(UsageUpdate)
    /// Any variant added by a newer agent that we don't model yet.
    case other(kind: String, payload: JSONValue)

    /// The discriminator string as sent on the wire.
    public var kind: String {
        switch self {
        case .agentMessageChunk: return "agent_message_chunk"
        case .agentThoughtChunk: return "agent_thought_chunk"
        case .userMessageChunk: return "user_message_chunk"
        case .toolCall: return "tool_call"
        case .toolCallUpdate: return "tool_call_update"
        case .plan: return "plan"
        case .availableCommandsUpdate: return "available_commands_update"
        case .currentModeUpdate: return "current_mode_update"
        case .usageUpdate: return "usage_update"
        case .other(let kind, _): return kind
        }
    }

    private enum Keys: String, CodingKey {
        case sessionUpdate, content, entries, availableCommands, currentModeId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(String.self, forKey: .sessionUpdate)
        switch kind {
        case "agent_message_chunk":
            self = .agentMessageChunk(try container.decode(ContentBlock.self, forKey: .content))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try container.decode(ContentBlock.self, forKey: .content))
        case "user_message_chunk":
            self = .userMessageChunk(try container.decode(ContentBlock.self, forKey: .content))
        case "tool_call":
            self = .toolCall(try ToolCall(from: decoder))
        case "tool_call_update":
            self = .toolCallUpdate(try ToolCallUpdate(from: decoder))
        case "plan":
            self = .plan(try container.decode([PlanEntry].self, forKey: .entries))
        case "available_commands_update":
            self = .availableCommandsUpdate(
                try container.decode([AvailableCommand].self, forKey: .availableCommands))
        case "current_mode_update":
            self = .currentModeUpdate(modeId: try container.decode(String.self, forKey: .currentModeId))
        case "usage_update":
            self = .usageUpdate(try UsageUpdate(from: decoder))
        default:
            self = .other(kind: kind, payload: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(kind, forKey: .sessionUpdate)
        switch self {
        case .agentMessageChunk(let c), .agentThoughtChunk(let c), .userMessageChunk(let c):
            try container.encode(c, forKey: .content)
        case .toolCall(let call):
            try call.encode(to: encoder)
        case .toolCallUpdate(let update):
            try update.encode(to: encoder)
        case .plan(let entries):
            try container.encode(entries, forKey: .entries)
        case .availableCommandsUpdate(let commands):
            try container.encode(commands, forKey: .availableCommands)
        case .currentModeUpdate(let modeId):
            try container.encode(modeId, forKey: .currentModeId)
        case .usageUpdate(let usage):
            try usage.encode(to: encoder)
        case .other(_, let payload):
            try payload.encode(to: encoder)
        }
    }
}

/// A `usage_update`: the agent's running context-window fill (`used` / `size`),
/// an optional cumulative `cost`, and — when the agent populates it — a per-turn
/// token breakdown under `_meta.usage` (Claude Code does; Codex doesn't, sending
/// only `used` / `size`). https://agentclientprotocol.com/protocol/v1/prompt-turn
public struct UsageUpdate: Codable, Sendable {
    /// Tokens used in the context window.
    public var used: Int?
    /// Context window size in tokens.
    public var size: Int?
    /// Cumulative session cost, when the agent reports it.
    public var cost: UsageCost?
    /// `_meta`, which may carry a `usage` token breakdown.
    public var meta: JSONValue?

    public struct UsageCost: Codable, Sendable {
        public var amount: Double?
        public var currency: String?
        public init(amount: Double? = nil, currency: String? = nil) {
            self.amount = amount
            self.currency = currency
        }
    }

    public init(
        used: Int? = nil, size: Int? = nil, cost: UsageCost? = nil, meta: JSONValue? = nil
    ) {
        self.used = used
        self.size = size
        self.cost = cost
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case used, size, cost
        case meta = "_meta"
    }
}

// MARK: - Tool calls

/// A tool the agent is about to run or is running.
/// https://agentclientprotocol.com/protocol/v1/tool-calls
public struct ToolCall: Codable, Sendable {
    public var toolCallId: String
    public var title: String
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?

    public init(
        toolCallId: String, title: String, kind: ToolKind? = nil,
        status: ToolCallStatus? = nil, content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil, rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }
}

/// An incremental update to a previously announced tool call. All fields except
/// the id are optional — only what changed is sent.
public struct ToolCallUpdate: Codable, Sendable {
    public var toolCallId: String
    public var title: String?
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?

    public init(
        toolCallId: String, title: String? = nil, kind: ToolKind? = nil,
        status: ToolCallStatus? = nil, content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil, rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }
}

public struct ToolCallLocation: Codable, Sendable, Hashable {
    public var path: String
    public var line: Int?
    public init(path: String, line: Int? = nil) {
        self.path = path
        self.line = line
    }
}

/// Content produced by a tool call: regular content, a file diff, or a terminal.
public enum ToolCallContent: Codable, Sendable {
    case content(ContentBlock)
    case diff(Diff)
    case terminal(terminalId: String)
    case other(JSONValue)

    public struct Diff: Codable, Sendable, Hashable {
        public var path: String
        public var oldText: String?
        public var newText: String
        public init(path: String, oldText: String? = nil, newText: String) {
            self.path = path
            self.oldText = oldText
            self.newText = newText
        }
    }

    private enum Keys: String, CodingKey {
        case type, content, path, oldText, newText, terminalId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        switch type {
        case "content":
            self = .content(try container.decode(ContentBlock.self, forKey: .content))
        case "diff":
            self = .diff(
                Diff(
                    path: try container.decode(String.self, forKey: .path),
                    oldText: try container.decodeIfPresent(String.self, forKey: .oldText),
                    newText: try container.decode(String.self, forKey: .newText)))
        case "terminal":
            self = .terminal(terminalId: try container.decode(String.self, forKey: .terminalId))
        default:
            self = .other(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .content(let block):
            try container.encode("content", forKey: .type)
            try container.encode(block, forKey: .content)
        case .diff(let diff):
            try container.encode("diff", forKey: .type)
            try container.encode(diff.path, forKey: .path)
            try container.encodeIfPresent(diff.oldText, forKey: .oldText)
            try container.encode(diff.newText, forKey: .newText)
        case .terminal(let terminalId):
            try container.encode("terminal", forKey: .type)
            try container.encode(terminalId, forKey: .terminalId)
        case .other(let payload):
            try payload.encode(to: encoder)
        }
    }
}

// MARK: - Plan

public struct PlanEntry: Codable, Sendable, Hashable {
    public var content: String
    public var priority: PlanEntryPriority?
    public var status: PlanEntryStatus?

    public init(content: String, priority: PlanEntryPriority? = nil, status: PlanEntryStatus? = nil) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

// MARK: - Slash commands

public struct AvailableCommand: Codable, Sendable {
    public var name: String
    public var description: String?
    public var input: JSONValue?

    public init(name: String, description: String? = nil, input: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.input = input
    }

    enum CodingKeys: String, CodingKey {
        case name, description, input
    }

    // Agents advertise commands either as bare strings (codex) or objects
    // (claude); accept both, mirroring acpx's `runtimeAvailableCommand`.
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let name = try? single.decode(String.self) {
            self.name = name
            self.description = nil
            self.input = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.input = try container.decodeIfPresent(JSONValue.self, forKey: .input)
    }
}
