import Foundation
import JSONFoundation

/// Dynamic key for the single-key tagged unions in the Zed conversation schema
/// (`{"User": …}`, `{"Text": …}`, etc.).
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - Messages

/// One element of a session's `messages` array.
public enum SessionMessage: Codable, Sendable {
    case resume
    case user(SessionUserMessage)
    case agent(SessionAgentMessage)

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            if s == "Resume" {
                self = .resume
                return
            }
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        if let user = try c.decodeIfPresent(SessionUserMessage.self, forKey: AnyKey("User")) {
            self = .user(user)
        } else if let agent = try c.decodeIfPresent(SessionAgentMessage.self, forKey: AnyKey("Agent")) {
            self = .agent(agent)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown session message"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .resume:
            var c = encoder.singleValueContainer()
            try c.encode("Resume")
        case .user(let value):
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(value, forKey: AnyKey("User"))
        case .agent(let value):
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(value, forKey: AnyKey("Agent"))
        }
    }
}

public struct SessionUserMessage: Codable, Sendable {
    public var id: String
    public var content: [SessionUserContent]
    public init(id: String, content: [SessionUserContent]) {
        self.id = id
        self.content = content
    }
}

public struct SessionAgentMessage: Codable, Sendable {
    public var content: [SessionAgentContent]
    public var toolResults: [String: SessionToolResult]
    public var reasoningDetails: JSONValue?

    public init(
        content: [SessionAgentContent],
        toolResults: [String: SessionToolResult] = [:],
        reasoningDetails: JSONValue? = nil
    ) {
        self.content = content
        self.toolResults = toolResults
        self.reasoningDetails = reasoningDetails
    }
}

// MARK: - User content

public enum SessionUserContent: Codable, Sendable {
    case text(String)
    case mention(uri: String, content: String)
    case image(SessionMessageImage)
    case audio(SessionMessageAudio)
    case other(JSONValue)

    struct Mention: Codable, Sendable {
        var uri: String
        var content: String
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        if let text = try c.decodeIfPresent(String.self, forKey: AnyKey("Text")) {
            self = .text(text)
        } else if let mention = try c.decodeIfPresent(Mention.self, forKey: AnyKey("Mention")) {
            self = .mention(uri: mention.uri, content: mention.content)
        } else if let image = try c.decodeIfPresent(SessionMessageImage.self, forKey: AnyKey("Image")) {
            self = .image(image)
        } else if let audio = try c.decodeIfPresent(SessionMessageAudio.self, forKey: AnyKey("Audio")) {
            self = .audio(audio)
        } else {
            self = .other(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .text(let value): try c.encode(value, forKey: AnyKey("Text"))
        case .mention(let uri, let content):
            try c.encode(Mention(uri: uri, content: content), forKey: AnyKey("Mention"))
        case .image(let value): try c.encode(value, forKey: AnyKey("Image"))
        case .audio(let value): try c.encode(value, forKey: AnyKey("Audio"))
        case .other(let value): try value.encode(to: encoder)
        }
    }

    /// Preview text per acpx `userContentToText`.
    public var previewText: String {
        switch self {
        case .text(let t): return t
        case .mention(_, let content): return content
        case .image(let image): return image.source.isEmpty ? "[image]" : image.source
        case .audio(let audio): return "[audio] \(audio.mimeType ?? "audio")"
        case .other: return ""
        }
    }
}

// MARK: - Agent content

public enum SessionAgentContent: Codable, Sendable {
    case text(String)
    case thinking(text: String, signature: String?)
    case redactedThinking(String)
    case toolUse(SessionToolUse)
    case other(JSONValue)

    struct Thinking: Codable, Sendable {
        var text: String
        var signature: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        if let text = try c.decodeIfPresent(String.self, forKey: AnyKey("Text")) {
            self = .text(text)
        } else if let thinking = try c.decodeIfPresent(Thinking.self, forKey: AnyKey("Thinking")) {
            self = .thinking(text: thinking.text, signature: thinking.signature)
        } else if let redacted = try c.decodeIfPresent(String.self, forKey: AnyKey("RedactedThinking")) {
            self = .redactedThinking(redacted)
        } else if let tool = try c.decodeIfPresent(SessionToolUse.self, forKey: AnyKey("ToolUse")) {
            self = .toolUse(tool)
        } else {
            self = .other(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .text(let value): try c.encode(value, forKey: AnyKey("Text"))
        case .thinking(let text, let signature):
            try c.encode(Thinking(text: text, signature: signature), forKey: AnyKey("Thinking"))
        case .redactedThinking(let value): try c.encode(value, forKey: AnyKey("RedactedThinking"))
        case .toolUse(let value): try c.encode(value, forKey: AnyKey("ToolUse"))
        case .other(let value): try value.encode(to: encoder)
        }
    }

    /// Preview text per acpx `agentContentToText`.
    public var previewText: String {
        switch self {
        case .text(let t): return t
        case .thinking(let text, _): return text
        case .redactedThinking: return "[redacted_thinking]"
        case .toolUse(let tool): return "[tool:\(tool.name)]"
        case .other: return ""
        }
    }
}

// MARK: - Leaf content types

public struct SessionMessageImage: Codable, Sendable {
    public var source: String
    public var size: Size?
    public struct Size: Codable, Sendable {
        public var width: Double
        public var height: Double
    }
}

public struct SessionMessageAudio: Codable, Sendable {
    public var source: String
    public var mimeType: String?
}

public struct SessionToolUse: Codable, Sendable {
    public var id: String
    public var name: String
    public var rawInput: String
    public var input: JSONValue?
    public var isInputComplete: Bool
    // `string | null | absent` — acpx persists it present-but-null for tool uses,
    // so distinguish present-null from absent to round-trip without data loss.
    public var thoughtSignature: Nullable<String>?

    enum CodingKeys: String, CodingKey {
        case id, name, input, rawInput, isInputComplete, thoughtSignature
    }

    public init(
        id: String, name: String, rawInput: String, input: JSONValue?,
        isInputComplete: Bool, thoughtSignature: Nullable<String>? = nil
    ) {
        self.id = id
        self.name = name
        self.rawInput = rawInput
        self.input = input
        self.isInputComplete = isInputComplete
        self.thoughtSignature = thoughtSignature
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rawInput = try c.decode(String.self, forKey: .rawInput)
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input)
        isInputComplete = try c.decode(Bool.self, forKey: .isInputComplete)
        thoughtSignature =
            c.contains(.thoughtSignature)
            ? try c.decode(Nullable<String>.self, forKey: .thoughtSignature) : nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(rawInput, forKey: .rawInput)
        try c.encodeIfPresent(input, forKey: .input)
        try c.encode(isInputComplete, forKey: .isInputComplete)
        try c.encodeIfPresent(thoughtSignature, forKey: .thoughtSignature)
    }
}

public struct SessionToolResult: Codable, Sendable {
    public var toolUseId: String
    public var toolName: String
    public var isError: Bool
    public var content: JSONValue
    public var output: JSONValue?
}

// MARK: - Token usage / cost / acpx state

public struct SessionTokenUsage: Codable, Sendable {
    public var inputTokens: Double?
    public var outputTokens: Double?
    public var cacheCreationInputTokens: Double?
    public var cacheReadInputTokens: Double?
    public var thoughtTokens: Double?
    public var totalTokens: Double?
    public init() {}
}

public struct SessionUsageCost: Codable, Sendable {
    public var amount: Double?
    public var currency: String?
}

/// The `acpx` runtime-state block of a session record.
public struct SessionAcpxState: Codable, Sendable {
    public var resetOnNextEnsure: Bool?
    public var currentModeId: String?
    public var desiredModeId: String?
    public var desiredConfigOptions: [String: String]?
    public var currentModelId: String?
    public var availableModels: [String]?
    public var modelControl: String?
    public var availableCommands: [AvailableCommand]?
    public var configOptions: JSONValue?
    public var sessionOptions: SessionOptions?

    /// A persisted slash command. Agents advertise these either as bare strings
    /// (codex: `"debug"`) or as objects (claude: `{name, description, has_input}`).
    /// acpx stores whichever form it received, so we preserve it for round-trip.
    public enum AvailableCommand: Codable, Sendable {
        case bare(String)
        case detailed(Detail)

        public struct Detail: Codable, Sendable {
            public var name: String
            public var description: String?
            public var hasInput: Bool?
        }

        public var name: String {
            switch self {
            case .bare(let name): return name
            case .detailed(let detail): return detail.name
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .bare(string)
            } else {
                self = .detailed(try container.decode(Detail.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bare(let string): try container.encode(string)
            case .detailed(let detail): try container.encode(detail)
            }
        }
    }

    public struct SessionOptions: Codable, Sendable {
        public var model: String?
        public var allowedTools: [String]?
        public var maxTurns: Int?
        public var systemPrompt: JSONValue? // string | {append}
        public init() {}
    }

    public init() {}
}
