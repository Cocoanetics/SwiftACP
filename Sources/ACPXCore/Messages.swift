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

    /// Preview text per acpx `userContentToText`.
    public var previewText: String {
        switch self {
        case .text(let t): return t
        case .mention(_, let content): return content
        // acpx returns `source` (the raw base64) here; ours is empty by design, so
        // name the type instead — a history listing wants a label, not a payload.
        case .image(let image):
            guard image.source.isEmpty else { return image.source }
            return "[image] \(image.mimeType ?? "image")"
        case .audio(let audio): return "[audio] \(audio.mimeType ?? "audio")"
        case .other: return ""
        }
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
    /// `size | null | absent`: acpx builds an image with a `null` size, and keeps
    /// whichever a record it read had.
    public var size: Nullable<Size>?
    /// The image's MIME type, when known. An acpx extension: upstream records omit it.
    public var mimeType: String?
    public struct Size: Codable, Sendable {
        public var width: Double
        public var height: Double
    }
}

extension SessionMessageImage {
    enum CodingKeys: String, CodingKey { case source, size, mimeType }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        size = c.contains(.size) ? try c.decode(Nullable<Size>.self, forKey: .size) : nil
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
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

/// The `acpx` runtime-state block of a session record.
public struct SessionAcpxState: Codable, Sendable {
    public var resetOnNextEnsure: Bool?
    public var currentModeId: String?
    public var desiredModeId: String?
    public var desiredConfigOptions: [String: String]?
    public var currentModelId: String?
    public var availableModels: [String]?
    /// Each advertised model's display name, by model id — acpx's `available_model_names`.
    public var availableModelNames: [String: String]?
    public var modelControl: String?
    public var availableCommands: [AvailableCommand]?
    public var configOptions: JSONValue?
    public var sessionOptions: SessionOptions?
    /// The session's own MCP servers (config-file entry shape), persisted as
    /// `mcp_servers`: set by the daemon's `newSession` / `setSessionMcpServers` or by
    /// creating the session under `--mcp-config`, and sent again on every reconnect.
    /// `nil` = the session uses the cwd's config-file servers. (A SwiftACP extension
    /// of the npm record: npm acpx keeps MCP servers per invocation, not per record.)
    public var mcpServers: [McpServerConfig]?
    /// The client capabilities the session was created under — what `--no-fs` and
    /// `--no-terminal` withheld — persisted as `client_capabilities` so every reconnect
    /// advertises the same ones. `nil` = the defaults.
    ///
    /// A SwiftACP extension of the npm record, like `mcp_servers`, and for the same
    /// reason: npm acpx carries capabilities on the queue owner that *is* the session,
    /// while `acpxd` outlives any one connection and has to read them back.
    public var clientCapabilities: PersistedCapabilities?
    /// The member order acpx gave each map of this block that it built anew since the
    /// record was read, by the map's name in the record: `available_model_names` from the
    /// models an agent advertised, `desired_config_options` from a control's reply —
    /// JavaScript objects, built by insertion (``ModelSupport``). A map not here keeps the
    /// order it was read with. Never written.
    var rebuiltOrders: [String: [String]] = [:]

    enum CodingKeys: String, CodingKey {
        case resetOnNextEnsure, currentModeId, desiredModeId, desiredConfigOptions, currentModelId
        case availableModels, availableModelNames, modelControl, availableCommands, configOptions
        case sessionOptions, mcpServers, clientCapabilities
    }

    /// The `fs` / `terminal` switches in the record's own shape.
    public struct PersistedCapabilities: Codable, Sendable, Hashable {
        public var readTextFile: Bool
        public var writeTextFile: Bool
        public var terminal: Bool

        public init(readTextFile: Bool, writeTextFile: Bool, terminal: Bool) {
            self.readTextFile = readTextFile
            self.writeTextFile = writeTextFile
            self.terminal = terminal
        }
    }

    /// A persisted slash command. Agents advertise these either as bare strings
    /// (codex: `"debug"`) or as objects (claude: `{name, description, has_input}`).
    /// acpx stores whichever form it received, so we preserve it for round-trip.
    public enum AvailableCommand: Codable, Sendable {
        case bare(String)
        case detailed(Detail)

        /// The object form's fields: name, optional description, and whether
        /// the command takes input.
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
        /// Environment variables the session's agent is started with, over this
        /// process's — acpx's `session_options.env` (0.14.0). Names keep their case.
        public var env: [String: String]?
        public init() {}

        enum CodingKeys: String, CodingKey {
            case model, allowedTools, maxTurns, systemPrompt, env
        }

        /// Each option read on its own, one that does not read left out; `env` keeps its
        /// string entries and is dropped when none is left — acpx's `storedEnvRecord`.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil
            allowedTools = (try? container.decodeIfPresent([String].self, forKey: .allowedTools)) ?? nil
            maxTurns = (try? container.decodeIfPresent(Int.self, forKey: .maxTurns)) ?? nil
            systemPrompt = (try? container.decodeIfPresent(JSONValue.self, forKey: .systemPrompt)) ?? nil
            let stored = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .env)) ?? nil
            let strings = (stored ?? [:]).compactMapValues { value -> String? in
                if case .string(let text) = value { return text }
                return nil
            }
            env = strings.isEmpty ? nil : strings
        }
    }

    public init() {}
}

extension SessionAcpxState {
    /// Each field read on its own, and one that does not read left out rather than failing
    /// the record: acpx drops what it cannot read in this block and keeps the record
    /// (`parseAcpxState`), and so does SwiftACP.
    ///
    /// SwiftACP's own `mcp_servers` and `client_capabilities`, which acpx never reads,
    /// restrict a session, so one that does not read fails closed: no MCP servers rather
    /// than the config file's, and no client capabilities rather than the defaults — a
    /// session created under `--no-fs` must not get the filesystem back.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        resetOnNextEnsure = field(.resetOnNextEnsure)
        currentModeId = field(.currentModeId)
        desiredModeId = field(.desiredModeId)
        desiredConfigOptions = field(.desiredConfigOptions)
        currentModelId = field(.currentModelId)
        availableModels = field(.availableModels)
        availableModelNames = field(.availableModelNames)
        modelControl = field(.modelControl)
        availableCommands = field(.availableCommands)
        configOptions = field(.configOptions)
        sessionOptions = field(.sessionOptions)
        // `try?` would make an absent field look like one that did not read.
        do {
            mcpServers = try container.decodeIfPresent([McpServerConfig].self, forKey: .mcpServers)
        } catch {
            mcpServers = []
        }
        do {
            clientCapabilities = try container.decodeIfPresent(PersistedCapabilities.self, forKey: .clientCapabilities)
        } catch {
            clientCapabilities = PersistedCapabilities(readTextFile: false, writeTextFile: false, terminal: false)
        }
    }
}
