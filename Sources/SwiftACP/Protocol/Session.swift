import Foundation
import JSONFoundation

public typealias SessionId = String

// MARK: - session/new

public struct NewSessionRequest: Codable, Sendable {
    public var cwd: String
    public var mcpServers: [MCPServerSpec]
    public var additionalDirectories: [String]?
    public var meta: JSONValue?

    public init(
        cwd: String,
        mcpServers: [MCPServerSpec] = [],
        additionalDirectories: [String]? = nil,
        meta: JSONValue? = nil
    ) {
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.additionalDirectories = additionalDirectories
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case cwd, mcpServers, additionalDirectories
        case meta = "_meta"
    }
}

public struct NewSessionResponse: Codable, Sendable {
    public var sessionId: SessionId
    public var modes: SessionModeState?
    public var configOptions: [JSONValue]?
    /// Legacy model advertisement (`{ currentModelId, availableModels }`), used
    /// by agents like Codex that don't expose models as config options.
    public var models: JSONValue?
    public var meta: JSONValue?

    public init(
        sessionId: SessionId,
        modes: SessionModeState? = nil,
        configOptions: [JSONValue]? = nil,
        models: JSONValue? = nil,
        meta: JSONValue? = nil
    ) {
        self.sessionId = sessionId
        self.modes = modes
        self.configOptions = configOptions
        self.models = models
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case sessionId, modes, configOptions, models
        case meta = "_meta"
    }
}

// MARK: - session/load

public struct LoadSessionRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var cwd: String
    public var mcpServers: [MCPServerSpec]
    public var additionalDirectories: [String]?
    public var meta: JSONValue?

    public init(
        sessionId: SessionId,
        cwd: String,
        mcpServers: [MCPServerSpec] = [],
        additionalDirectories: [String]? = nil,
        meta: JSONValue? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.additionalDirectories = additionalDirectories
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, cwd, mcpServers, additionalDirectories
        case meta = "_meta"
    }
}

public struct LoadSessionResponse: Codable, Sendable {
    public var modes: SessionModeState?
    public var configOptions: [JSONValue]?
    /// Legacy model advertisement (`{ currentModelId, availableModels }`), used
    /// by agents like Codex that don't expose models as config options.
    public var models: JSONValue?
    public var meta: JSONValue?

    public init(
        modes: SessionModeState? = nil,
        configOptions: [JSONValue]? = nil,
        models: JSONValue? = nil,
        meta: JSONValue? = nil
    ) {
        self.modes = modes
        self.configOptions = configOptions
        self.models = models
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case modes, configOptions, models
        case meta = "_meta"
    }
}

// MARK: - session/resume

public struct ResumeSessionRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var cwd: String
    public var mcpServers: [MCPServerSpec]
    public var additionalDirectories: [String]?
    public var meta: JSONValue?

    public init(
        sessionId: SessionId, cwd: String, mcpServers: [MCPServerSpec] = [],
        additionalDirectories: [String]? = nil, meta: JSONValue? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.additionalDirectories = additionalDirectories
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, cwd, mcpServers, additionalDirectories
        case meta = "_meta"
    }
}

public typealias ResumeSessionResponse = LoadSessionResponse

// MARK: - session/prompt

public struct PromptRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var prompt: [ContentBlock]
    public var meta: JSONValue?

    public init(sessionId: SessionId, prompt: [ContentBlock], meta: JSONValue? = nil) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, prompt
        case meta = "_meta"
    }
}

public struct PromptResponse: Codable, Sendable {
    public var stopReason: StopReason
    /// The turn's token usage, when the agent reports it on the response. Claude
    /// Code populates this (Codex doesn't). Note: this is where the breakdown
    /// actually rides — *not* `usage_update._meta.usage`, which agents leave empty.
    public var usage: PromptUsage?

    public init(stopReason: StopReason, usage: PromptUsage? = nil) {
        self.stopReason = stopReason
        self.usage = usage
    }
}

/// A prompt response's per-turn token breakdown (camelCase on the wire).
public struct PromptUsage: Codable, Sendable {
    public var inputTokens: Double?
    public var outputTokens: Double?
    public var cachedReadTokens: Double?
    public var cachedWriteTokens: Double?
    public var thoughtTokens: Double?
    public var totalTokens: Double?

    public init(
        inputTokens: Double? = nil, outputTokens: Double? = nil, cachedReadTokens: Double? = nil,
        cachedWriteTokens: Double? = nil, thoughtTokens: Double? = nil, totalTokens: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedReadTokens = cachedReadTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.thoughtTokens = thoughtTokens
        self.totalTokens = totalTokens
    }

    /// Decoding accepts the same spellings acpx's `sourceToTokenUsage` does — snake_case
    /// first, then camelCase, then the `cached*` aliases — and ignores a value that is
    /// not a finite, non-negative number, trying the next spelling instead (acpx's
    /// `numberField`). Encoding stays camelCase, the shape acpx writes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        inputTokens = Self.number(container, ["input_tokens", "inputTokens"])
        outputTokens = Self.number(container, ["output_tokens", "outputTokens"])
        cachedWriteTokens = Self.number(
            container,
            ["cache_creation_input_tokens", "cacheCreationInputTokens", "cachedWriteTokens"])
        cachedReadTokens = Self.number(
            container, ["cache_read_input_tokens", "cacheReadInputTokens", "cachedReadTokens"])
        thoughtTokens = Self.number(container, ["thought_tokens", "thoughtTokens"])
        totalTokens = Self.number(container, ["total_tokens", "totalTokens"])
    }

    private static func number(
        _ container: KeyedDecodingContainer<AnyCodingKey>, _ keys: [String]
    ) -> Double? {
        for key in keys {
            guard let value = try? container.decodeIfPresent(Double.self, forKey: AnyCodingKey(key)),
                value.isFinite, value >= 0
            else { continue }
            return value
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cachedReadTokens, cachedWriteTokens
        case thoughtTokens, totalTokens
    }

    /// A coding key for any of the spellings above.
    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

// MARK: - session/cancel (notification)

public struct CancelNotification: Codable, Sendable {
    public var sessionId: SessionId
    public init(sessionId: SessionId) { self.sessionId = sessionId }
}

// MARK: - session modes

/// The agent's mode menu for a session: which mode is active and which are
/// available. Advertised on `session/new` / `session/load`.
public struct SessionModeState: Codable, Hashable, Sendable {
    public var currentModeId: String
    public var availableModes: [SessionMode]

    public init(currentModeId: String, availableModes: [SessionMode]) {
        self.currentModeId = currentModeId
        self.availableModes = availableModes
    }
}

/// One operating mode the agent offers (e.g. "ask", "code"); switched with
/// `session/set_mode` and reported back via `current_mode_update`.
public struct SessionMode: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct SetSessionModeRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var modeId: String
    public init(sessionId: SessionId, modeId: String) {
        self.sessionId = sessionId
        self.modeId = modeId
    }
}

public struct SetSessionConfigOptionRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var configId: String
    public var value: String
    public init(sessionId: SessionId, configId: String, value: String) {
        self.sessionId = sessionId
        self.configId = configId
        self.value = value
    }
}

/// `session/set_config_option` response — the agent's full set of config options
/// after the change (each opaque, since the schema is agent-specific).
public struct SetSessionConfigOptionResponse: Codable, Sendable {
    public var configOptions: [JSONValue]?
    public init(configOptions: [JSONValue]? = nil) {
        self.configOptions = configOptions
    }
}

// MARK: - session models

/// The agent's advertised model menu — returned on `session/new` / `session/load`
/// (carried in the passthrough `models` field) and surfaced by clients as a model
/// picker. Mirrors ACP's `SessionModelState`. Switching is driven by
/// ``SetSessionModelRequest`` (`session/set_model`).
public struct SessionModelState: Codable, Hashable, Sendable {
    /// The model the session is currently using, if known.
    public var currentModelId: String?
    /// The models the agent offers for this session.
    public var availableModels: [ModelInfo]
    public init(currentModelId: String? = nil, availableModels: [ModelInfo]) {
        self.currentModelId = currentModelId
        self.availableModels = availableModels
    }
}

/// One entry in a ``SessionModelState`` model menu.
public struct ModelInfo: Codable, Hashable, Sendable {
    public var modelId: String
    public var name: String
    public var description: String?
    public init(modelId: String, name: String, description: String? = nil) {
        self.modelId = modelId
        self.name = name
        self.description = description
    }
}

/// `session/set_model` — switch the session's active model. The available ids
/// come from the ``SessionModelState`` advertised at session creation.
public struct SetSessionModelRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var modelId: String
    public init(sessionId: SessionId, modelId: String) {
        self.sessionId = sessionId
        self.modelId = modelId
    }
}

public extension NewSessionResponse {
    /// Build a response that advertises a typed model menu, encoding it into the
    /// passthrough `models` field (kept opaque so unknown agent shapes round-trip).
    init(
        sessionId: SessionId,
        modelState: SessionModelState,
        modes: SessionModeState? = nil,
        configOptions: [JSONValue]? = nil,
        meta: JSONValue? = nil
    ) {
        self.init(
            sessionId: sessionId, modes: modes, configOptions: configOptions,
            models: try? JSONValue(encoding: modelState), meta: meta
        )
    }
}

public extension LoadSessionResponse {
    /// Re-advertise a typed model menu on `session/load`, encoding it into the
    /// passthrough `models` field — the resume counterpart of
    /// ``NewSessionResponse/init(sessionId:modelState:modes:configOptions:meta:)``
    /// so a reconnecting client re-renders the same model/mode pickers.
    init(
        modelState: SessionModelState,
        modes: SessionModeState? = nil,
        configOptions: [JSONValue]? = nil
    ) {
        self.init(
            modes: modes, configOptions: configOptions,
            models: try? JSONValue(encoding: modelState)
        )
    }
}
