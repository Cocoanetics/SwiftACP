import Foundation
import JSONValue

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
    public var models: JSONValue?

    public init(modes: SessionModeState? = nil, configOptions: [JSONValue]? = nil) {
        self.modes = modes
        self.configOptions = configOptions
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
}

// MARK: - session/cancel (notification)

public struct CancelNotification: Codable, Sendable {
    public var sessionId: SessionId
    public init(sessionId: SessionId) { self.sessionId = sessionId }
}

// MARK: - session modes

public struct SessionModeState: Codable, Hashable, Sendable {
    public var currentModeId: String
    public var availableModes: [SessionMode]
}

public struct SessionMode: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
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
