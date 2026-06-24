import Foundation
import JSONFoundation

/// A field that is `T`, JSON `null`, or absent — preserved distinctly so output
/// is byte-faithful (e.g. `last_agent_exit_code: null` vs omitted).
public enum Nullable<Wrapped: Codable & Sendable>: Codable, Sendable {
    case null
    case value(Wrapped)

    public var value: Wrapped? {
        if case .value(let v) = self { return v }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else {
            self = .value(try container.decode(Wrapped.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .value(let v): try container.encode(v)
        }
    }
}

public let SESSION_RECORD_SCHEMA = "acpx.session.v1"
public let SESSION_INDEX_SCHEMA = "acpx.session-index.v1"
public let DEFAULT_EVENT_SEGMENT_MAX_BYTES = 64 * 1024 * 1024
public let DEFAULT_EVENT_MAX_SEGMENTS = 5

/// A persisted acpx session (`~/.acpx/sessions/<id>.json`), serialized with the
/// exact snake_case keys acpx 0.11.0 uses (`persistence/serialize.ts`). Complex
/// Zed-schema substructures are kept as opaque `JSONValue` and round-tripped
/// verbatim; helpers interpret them where commands need to (history, acpx state).
public struct SessionRecord: Codable, Sendable {
    public var schema = SESSION_RECORD_SCHEMA
    public var acpxRecordId: String
    public var acpSessionId: String
    public var agentSessionId: String?
    public var agentCommand: String
    public var cwd: String
    public var name: String?
    public var createdAt: String
    public var lastUsedAt: String
    public var lastSeq: Int
    public var lastRequestId: String?
    public var eventLog: SessionEventLog
    public var closed: Bool?
    public var closedAt: String?
    public var pid: Int?
    public var agentStartedAt: String?
    public var lastPromptAt: String?
    public var lastAgentExitCode: Nullable<Int>?
    public var lastAgentExitSignal: Nullable<String>?
    public var lastAgentExitAt: String?
    public var lastAgentDisconnectReason: String?
    public var protocolVersion: Int?
    public var agentCapabilities: JSONValue?
    public var title: String?
    public var messages: [SessionMessage]
    public var updatedAt: String
    public var cumulativeTokenUsage: SessionTokenUsage?
    public var cumulativeCost: SessionUsageCost?
    public var requestTokenUsage: [String: SessionTokenUsage]?
    public var acpx: SessionAcpxState?
    public var importedFrom: ImportedFrom?

    public struct ImportedFrom: Codable, Sendable {
        public var recordId: String
        public var cwdOriginal: String
        public var exportedBy: String
        public var exportedAt: String
    }

    // camelCase property names; the disk encoder/decoder translate to/from
    // snake_case via key strategies (see Coders.swift).
    enum CodingKeys: String, CodingKey {
        case schema, acpxRecordId, acpSessionId, agentSessionId, agentCommand, cwd, name
        case createdAt, lastUsedAt, lastSeq, lastRequestId, eventLog, closed, closedAt, pid
        case agentStartedAt, lastPromptAt, lastAgentExitCode, lastAgentExitSignal, lastAgentExitAt
        case lastAgentDisconnectReason, protocolVersion, agentCapabilities, title, messages
        case updatedAt, cumulativeTokenUsage, cumulativeCost, requestTokenUsage, acpx, importedFrom
    }

    public init(
        acpxRecordId: String,
        acpSessionId: String,
        agentCommand: String,
        cwd: String,
        name: String? = nil,
        createdAt: String,
        lastUsedAt: String,
        agentSessionId: String? = nil
    ) {
        self.acpxRecordId = acpxRecordId
        self.acpSessionId = acpSessionId
        self.agentSessionId = agentSessionId
        self.agentCommand = agentCommand
        self.cwd = cwd
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastSeq = 0
        self.eventLog = SessionEventLog(recordId: acpxRecordId)
        self.messages = []
        self.updatedAt = lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? SESSION_RECORD_SCHEMA
        acpxRecordId = try c.decode(String.self, forKey: .acpxRecordId)
        acpSessionId = try c.decode(String.self, forKey: .acpSessionId)
        agentSessionId = try c.decodeIfPresent(String.self, forKey: .agentSessionId)
        agentCommand = try c.decode(String.self, forKey: .agentCommand)
        cwd = try c.decode(String.self, forKey: .cwd)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        lastUsedAt = try c.decode(String.self, forKey: .lastUsedAt)
        lastSeq = try c.decodeIfPresent(Int.self, forKey: .lastSeq) ?? 0
        lastRequestId = try c.decodeIfPresent(String.self, forKey: .lastRequestId)
        eventLog =
            try c.decodeIfPresent(SessionEventLog.self, forKey: .eventLog)
            ?? SessionEventLog(recordId: acpxRecordId)
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed)
        closedAt = try c.decodeIfPresent(String.self, forKey: .closedAt)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        agentStartedAt = try c.decodeIfPresent(String.self, forKey: .agentStartedAt)
        lastPromptAt = try c.decodeIfPresent(String.self, forKey: .lastPromptAt)
        // `decodeIfPresent` collapses JSON null to nil; use `contains` to keep
        // present-null distinct from absent (byte-faithful output).
        lastAgentExitCode =
            c.contains(.lastAgentExitCode) ? try c.decode(Nullable<Int>.self, forKey: .lastAgentExitCode) : nil
        lastAgentExitSignal =
            c.contains(.lastAgentExitSignal)
            ? try c.decode(Nullable<String>.self, forKey: .lastAgentExitSignal) : nil
        lastAgentExitAt = try c.decodeIfPresent(String.self, forKey: .lastAgentExitAt)
        lastAgentDisconnectReason = try c.decodeIfPresent(
            String.self, forKey: .lastAgentDisconnectReason)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion)
        agentCapabilities = try c.decodeIfPresent(JSONValue.self, forKey: .agentCapabilities)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        messages = try c.decodeIfPresent([SessionMessage].self, forKey: .messages) ?? []
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? lastUsedAt
        cumulativeTokenUsage = try c.decodeIfPresent(SessionTokenUsage.self, forKey: .cumulativeTokenUsage)
        cumulativeCost = try c.decodeIfPresent(SessionUsageCost.self, forKey: .cumulativeCost)
        requestTokenUsage = try c.decodeIfPresent([String: SessionTokenUsage].self, forKey: .requestTokenUsage)
        acpx = try c.decodeIfPresent(SessionAcpxState.self, forKey: .acpx)
        importedFrom = try c.decodeIfPresent(ImportedFrom.self, forKey: .importedFrom)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(acpxRecordId, forKey: .acpxRecordId)
        try c.encode(acpSessionId, forKey: .acpSessionId)
        try c.encodeIfPresent(agentSessionId, forKey: .agentSessionId)
        try c.encode(agentCommand, forKey: .agentCommand)
        try c.encode(cwd, forKey: .cwd)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastUsedAt, forKey: .lastUsedAt)
        try c.encode(lastSeq, forKey: .lastSeq)
        try c.encodeIfPresent(lastRequestId, forKey: .lastRequestId)
        try c.encode(eventLog, forKey: .eventLog)
        try c.encodeIfPresent(closed, forKey: .closed)
        try c.encodeIfPresent(closedAt, forKey: .closedAt)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(agentStartedAt, forKey: .agentStartedAt)
        try c.encodeIfPresent(lastPromptAt, forKey: .lastPromptAt)
        try c.encodeIfPresent(lastAgentExitCode, forKey: .lastAgentExitCode)
        try c.encodeIfPresent(lastAgentExitSignal, forKey: .lastAgentExitSignal)
        try c.encodeIfPresent(lastAgentExitAt, forKey: .lastAgentExitAt)
        try c.encodeIfPresent(lastAgentDisconnectReason, forKey: .lastAgentDisconnectReason)
        try c.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
        try c.encodeIfPresent(agentCapabilities, forKey: .agentCapabilities)
        // acpx always writes `title` (null when unset), via createSessionConversation.
        if let title { try c.encode(title, forKey: .title) } else { try c.encodeNil(forKey: .title) }
        try c.encode(messages, forKey: .messages)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(cumulativeTokenUsage ?? SessionTokenUsage(), forKey: .cumulativeTokenUsage)
        try c.encodeIfPresent(cumulativeCost, forKey: .cumulativeCost)
        try c.encode(requestTokenUsage ?? [:], forKey: .requestTokenUsage)
        try c.encodeIfPresent(acpx, forKey: .acpx)
        try c.encodeIfPresent(importedFrom, forKey: .importedFrom)
    }
}

/// The `event_log` block of a session record.
public struct SessionEventLog: Codable, Sendable {
    public var activePath: String
    public var segmentCount: Int
    public var maxSegmentBytes: Int
    public var maxSegments: Int
    public var lastWriteAt: String?
    public var lastWriteError: String?

    enum CodingKeys: String, CodingKey {
        case activePath, segmentCount, maxSegmentBytes, maxSegments, lastWriteAt, lastWriteError
    }

    public init(recordId: String) {
        self.activePath = ACPXPaths.sessionStreamPath(recordId).path
        self.segmentCount = DEFAULT_EVENT_MAX_SEGMENTS
        self.maxSegmentBytes = DEFAULT_EVENT_SEGMENT_MAX_BYTES
        self.maxSegments = DEFAULT_EVENT_MAX_SEGMENTS
        self.lastWriteError = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activePath = try c.decodeIfPresent(String.self, forKey: .activePath) ?? ""
        segmentCount = try c.decodeIfPresent(Int.self, forKey: .segmentCount) ?? DEFAULT_EVENT_MAX_SEGMENTS
        maxSegmentBytes =
            try c.decodeIfPresent(Int.self, forKey: .maxSegmentBytes) ?? DEFAULT_EVENT_SEGMENT_MAX_BYTES
        maxSegments = try c.decodeIfPresent(Int.self, forKey: .maxSegments) ?? DEFAULT_EVENT_MAX_SEGMENTS
        lastWriteAt = try c.decodeIfPresent(String.self, forKey: .lastWriteAt)
        // `last_write_error` is `null` when no error — preserve as nil.
        lastWriteError = try c.decodeIfPresent(String.self, forKey: .lastWriteError)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(activePath, forKey: .activePath)
        try c.encode(segmentCount, forKey: .segmentCount)
        try c.encode(maxSegmentBytes, forKey: .maxSegmentBytes)
        try c.encode(maxSegments, forKey: .maxSegments)
        try c.encodeIfPresent(lastWriteAt, forKey: .lastWriteAt)
        // acpx writes `last_write_error: null` explicitly.
        if let lastWriteError {
            try c.encode(lastWriteError, forKey: .lastWriteError)
        } else {
            try c.encodeNil(forKey: .lastWriteError)
        }
    }
}

/// One entry in `~/.acpx/sessions/index.json` (camelCase keys, unlike the record).
public struct SessionIndexEntry: Codable, Sendable {
    public var file: String
    public var acpxRecordId: String
    public var acpSessionId: String
    public var agentCommand: String
    public var cwd: String
    public var name: String?
    public var closed: Bool
    public var lastUsedAt: String

    public init(record: SessionRecord) {
        self.file = "\(ACPXPaths.safeSessionId(record.acpxRecordId)).json"
        self.acpxRecordId = record.acpxRecordId
        self.acpSessionId = record.acpSessionId
        self.agentCommand = record.agentCommand
        self.cwd = record.cwd
        self.name = record.name
        self.closed = record.closed == true
        self.lastUsedAt = record.lastUsedAt
    }
}

public struct SessionIndex: Codable, Sendable {
    public var schema = SESSION_INDEX_SCHEMA
    public var files: [String]
    public var entries: [SessionIndexEntry]

    public init(files: [String] = [], entries: [SessionIndexEntry] = []) {
        self.files = files
        self.entries = entries
    }
}
