import Foundation
import JSONFoundation

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
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        if let user = try c.decodeIfPresent(SessionUserMessage.self, forKey: AnyCodingKey("User")) {
            self = .user(user)
        } else if let agent = try c.decodeIfPresent(SessionAgentMessage.self, forKey: AnyCodingKey("Agent")) {
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
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            try c.encode(value, forKey: AnyCodingKey("User"))
        case .agent(let value):
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            try c.encode(value, forKey: AnyCodingKey("Agent"))
        }
    }
}

/// A persisted user turn (the `User` payload): prompt id plus its content blocks.
public struct SessionUserMessage: Codable, Sendable {
    public var id: String
    public var content: [SessionUserContent]
    public init(id: String, content: [SessionUserContent]) {
        self.id = id
        self.content = content
    }
}

/// A persisted agent turn (the `Agent` payload): content blocks plus the turn's
/// tool results keyed by tool-use id.
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

/// One content block of a persisted user message (`Text`/`Mention`/`Image`/`Audio`);
/// unrecognized shapes round-trip via `.other`.
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
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        if let text = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("Text")) {
            self = .text(text)
        } else if let mention = try c.decodeIfPresent(Mention.self, forKey: AnyCodingKey("Mention")) {
            self = .mention(uri: mention.uri, content: mention.content)
        } else if let image = try c.decodeIfPresent(SessionMessageImage.self, forKey: AnyCodingKey("Image")) {
            self = .image(image)
        } else if let audio = try c.decodeIfPresent(SessionMessageAudio.self, forKey: AnyCodingKey("Audio")) {
            self = .audio(audio)
        } else {
            self = .other(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        switch self {
        case .text(let value): try c.encode(value, forKey: AnyCodingKey("Text"))
        case .mention(let uri, let content):
            try c.encode(Mention(uri: uri, content: content), forKey: AnyCodingKey("Mention"))
        case .image(let value): try c.encode(value, forKey: AnyCodingKey("Image"))
        case .audio(let value): try c.encode(value, forKey: AnyCodingKey("Audio"))
        case .other(let value): try value.encode(to: encoder)
        }
    }

    /// Preview text per acpx `userContentToText`: an image or an audio clip by its type
    /// (`mime_type || "image"`), never by its data, as acpx 0.19.3 names it
    /// (openclaw/acpx#766).
    public var previewText: String {
        switch self {
        case .text(let t): return t
        case .mention(_, let content): return content
        case .image(let image): return "[image] \(Self.named(image.mimeType?.value, or: "image"))"
        case .audio(let audio): return "[audio] \(Self.named(audio.mimeType, or: "audio"))"
        case .other: return ""
        }
    }

    /// JavaScript's `type || fallback`: an empty type is no type.
    private static func named(_ type: String?, or fallback: String) -> String {
        guard let type, !type.isEmpty else { return fallback }
        return type
    }
}

// MARK: - Agent content

/// One content block of a persisted agent message (`Text`/`Thinking`/
/// `RedactedThinking`/`ToolUse`); unrecognized shapes round-trip via `.other`.
public enum SessionAgentContent: Codable, Sendable {
    case text(String)
    /// `signature` is `string | null | absent`: acpx builds thinking with a `null` one,
    /// and keeps whichever a record it read had.
    case thinking(text: String, signature: Nullable<String>?)
    case redactedThinking(String)
    case toolUse(SessionToolUse)
    case other(JSONValue)

    struct Thinking: Codable, Sendable {
        var text: String
        var signature: Nullable<String>?

        enum CodingKeys: String, CodingKey { case text, signature }

        init(text: String, signature: Nullable<String>?) {
            self.text = text
            self.signature = signature
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            signature = c.contains(.signature) ? try c.decode(Nullable<String>.self, forKey: .signature) : nil
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        if let text = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("Text")) {
            self = .text(text)
        } else if let thinking = try c.decodeIfPresent(Thinking.self, forKey: AnyCodingKey("Thinking")) {
            self = .thinking(text: thinking.text, signature: thinking.signature)
        } else if let redacted = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("RedactedThinking")) {
            self = .redactedThinking(redacted)
        } else if let tool = try c.decodeIfPresent(SessionToolUse.self, forKey: AnyCodingKey("ToolUse")) {
            self = .toolUse(tool)
        } else {
            self = .other(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        switch self {
        case .text(let value): try c.encode(value, forKey: AnyCodingKey("Text"))
        case .thinking(let text, let signature):
            try c.encode(Thinking(text: text, signature: signature), forKey: AnyCodingKey("Thinking"))
        case .redactedThinking(let value): try c.encode(value, forKey: AnyCodingKey("RedactedThinking"))
        case .toolUse(let value): try c.encode(value, forKey: AnyCodingKey("ToolUse"))
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

/// A persisted image block: its `source` string plus optional pixel dimensions.
///
/// `source` is acpx's field for the image's base64 data. We record the MIME type
/// instead and leave `source` empty — see
/// ``ConversationModel/recordPromptSubmission(into:prompt:timestamp:)-(_,[ContentBlock],_)``
/// — while still decoding a populated `source` from records acpx itself wrote.
public struct SessionMessageImage: Codable, Sendable {
    public var source: String
    /// `string | null | absent`: acpx records an image's MIME type since 0.19.3
    /// (openclaw/acpx#766), and keeps whichever a record it read had.
    public var mimeType: Nullable<String>?
    /// `size | null | absent`: acpx builds an image with a `null` size, and keeps
    /// whichever a record it read had.
    public var size: Nullable<Size>?
    public struct Size: Codable, Sendable {
        public var width: Double
        public var height: Double
    }
}

extension SessionMessageImage {
    enum CodingKeys: String, CodingKey { case source, mimeType, size }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        mimeType = c.contains(.mimeType) ? try c.decode(Nullable<String>.self, forKey: .mimeType) : nil
        size = c.contains(.size) ? try c.decode(Nullable<Size>.self, forKey: .size) : nil
    }
}

/// A persisted audio block: its `source` string plus optional MIME type.
public struct SessionMessageAudio: Codable, Sendable {
    public var source: String
    public var mimeType: String?
}

/// A tool call recorded in an agent message: id, name, raw + parsed input, and
/// whether input streaming completed.
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

/// The persisted outcome of a tool call, stored in
/// ``SessionAgentMessage/toolResults`` under its `toolUseId`.
public struct SessionToolResult: Codable, Sendable {
    public var toolUseId: String
    public var toolName: String
    public var isError: Bool
    public var content: JSONValue
    public var output: JSONValue?
}

// MARK: - Token usage / cost / acpx state

/// A session record's token counters. All optional doubles, matching the
/// JS numbers acpx persists.
public struct SessionTokenUsage: Codable, Sendable {
    public var inputTokens: Double?
    public var outputTokens: Double?
    public var cacheCreationInputTokens: Double?
    public var cacheReadInputTokens: Double?
    public var thoughtTokens: Double?
    public var totalTokens: Double?
    public init() {}
}

/// A session record's cost figure: amount plus currency code.
public struct SessionUsageCost: Codable, Sendable {
    public var amount: Double?
    public var currency: String?
}
