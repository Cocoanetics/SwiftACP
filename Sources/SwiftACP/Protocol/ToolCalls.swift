import Foundation
import JSONFoundation

// A tool the agent runs, and the updates to it — split from `SessionUpdate.swift` to keep that
// file inside the 500-line limit.

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
    /// The members the call sent as JSON `null` (`kind`, `status`, …). Each clears what an earlier
    /// update of the same tool set, as acpx's formatter merges them (`mergeToolPayloadState`), where
    /// a member left out leaves it as it was (#270 review). Sent back as `null`.
    public var nullMembers: Set<String> = []

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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case toolCallId, title, kind, status, content, locations, rawInput, rawOutput
    }

    /// Read as the ACP SDK reads a `tool_call` (`zToolCall`): the id and title are
    /// required, the rest is read leniently. A `kind` or `status` that doesn't fit is left
    /// out, and so are the `content` and `locations` entries that don't; either list is
    /// empty when it is no list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        title = try container.decode(String.self, forKey: .title)
        kind = container.lenient(ToolKind.self, forKey: .kind)
        status = container.lenient(ToolCallStatus.self, forKey: .status)
        content = container.lenientList(ToolCallContent.self, forKey: .content, fallback: [])
        locations = container.lenientList(ToolCallLocation.self, forKey: .locations, fallback: [])
        rawInput = try container.decodeIfPresent(JSONValue.self, forKey: .rawInput)
        rawOutput = try container.decodeIfPresent(JSONValue.self, forKey: .rawOutput)
        var nulled: Set<String> = []
        for key in CodingKeys.allCases where key != .toolCallId && key != .title && container.contains(key) {
            if try container.decodeNil(forKey: key) { nulled.insert(key.stringValue) }
        }
        nullMembers = nulled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(locations, forKey: .locations)
        try container.encodeIfPresent(rawInput, forKey: .rawInput)
        try container.encodeIfPresent(rawOutput, forKey: .rawOutput)
        // A member given a value since wins over the `null` it came as.
        for key in CodingKeys.allCases where nullMembers.contains(key.stringValue) && !hasValue(key) {
            try container.encodeNil(forKey: key)
        }
    }

    private func hasValue(_ key: CodingKeys) -> Bool {
        switch key {
        case .toolCallId, .title: return true
        case .kind: return kind != nil
        case .status: return status != nil
        case .content: return content != nil
        case .locations: return locations != nil
        case .rawInput: return rawInput != nil
        case .rawOutput: return rawOutput != nil
        }
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
    /// The members the update sent as JSON `null` (`kind`, `status`, …). Each clears
    /// what an earlier update set, where a member left out leaves it as it was — acpx's
    /// `mergeToolPayloadState`. Sent back as `null`.
    public var nullMembers: Set<String> = []

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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case toolCallId, title, kind, status, content, locations, rawInput, rawOutput
    }

    /// Read as the ACP SDK reads a `tool_call_update` (`zToolCallUpdate`): only the id is
    /// required. A member that doesn't fit is left out, as if not sent, and so are the
    /// `content` and `locations` entries that don't fit.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        title = container.lenient(String.self, forKey: .title)
        kind = container.lenient(ToolKind.self, forKey: .kind)
        status = container.lenient(ToolCallStatus.self, forKey: .status)
        content = container.lenientList(ToolCallContent.self, forKey: .content, fallback: nil)
        locations = container.lenientList(ToolCallLocation.self, forKey: .locations, fallback: nil)
        rawInput = try container.decodeIfPresent(JSONValue.self, forKey: .rawInput)
        rawOutput = try container.decodeIfPresent(JSONValue.self, forKey: .rawOutput)
        var nulled: Set<String> = []
        for key in CodingKeys.allCases where key != .toolCallId && container.contains(key) {
            if try container.decodeNil(forKey: key) { nulled.insert(key.stringValue) }
        }
        nullMembers = nulled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(locations, forKey: .locations)
        try container.encodeIfPresent(rawInput, forKey: .rawInput)
        try container.encodeIfPresent(rawOutput, forKey: .rawOutput)
        // A member given a value since wins over the `null` it came as.
        for key in CodingKeys.allCases where nullMembers.contains(key.stringValue) && !hasValue(key) {
            try container.encodeNil(forKey: key)
        }
    }

    private func hasValue(_ key: CodingKeys) -> Bool {
        switch key {
        case .toolCallId: return true
        case .title: return title != nil
        case .kind: return kind != nil
        case .status: return status != nil
        case .content: return content != nil
        case .locations: return locations != nil
        case .rawInput: return rawInput != nil
        case .rawOutput: return rawOutput != nil
        }
    }
}
