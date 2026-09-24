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
    /// The exact argv the agent is launched with (`agent_argv`), when it has one: a
    /// config agent's `argv`, or the built-in's. Without it, `agentCommand` is split.
    public var agentArgv: [String]?
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
    /// The conversation's title: `null` on disk until the agent names one, as acpx's
    /// `createSessionConversation` starts it.
    public var title: String? {
        get { storedTitle?.value }
        set { storedTitle = newValue.map(Nullable.value) ?? .null }
    }
    /// `title` as written: absent only when the record was read without one, as acpx's
    /// parser keeps it (`parseConversationTitle`).
    private var storedTitle: Nullable<String>? = .null
    public var messages: [SessionMessage]
    public var updatedAt: String
    public var cumulativeTokenUsage: SessionTokenUsage?
    public var cumulativeCost: SessionUsageCost?
    public var requestTokenUsage: [String: SessionTokenUsage]?
    public var acpx: SessionAcpxState?
    public var importedFrom: ImportedFrom?
    /// The record as acpx's parser made it of the file it was read from
    /// (``SessionRecordParser``) — what acpx prints for it in `--format json`. Set by
    /// ``SessionStore/readRecord(at:expecting:)``; `nil` for a record built in memory,
    /// and not updated by changes made since. Never written.
    public var parsedByAcpx: WireJSON?
    /// How many of the messages the record was read with have been trimmed away since,
    /// the oldest first (``ConversationModel``): what sits at a message's place in
    /// ``parsedByAcpx``, less these, is that message as it was read. Never written.
    public var messagesTrimmedSinceRead = 0
    /// The ids of the ``requestTokenUsage`` entries added since the record was read, in
    /// the order ``ConversationModel`` added them: acpx's object holds its entries in the
    /// order it got them, those it read first. Never written.
    var requestUsageAddedSinceRead: [String] = []

    public struct ImportedFrom: Codable, Sendable {
        public var recordId: String
        public var cwdOriginal: String
        public var exportedBy: String
        public var exportedAt: String
    }

    // camelCase property names; the disk encoder/decoder translate to/from
    // snake_case via key strategies (see Coders.swift).
    enum CodingKeys: String, CodingKey {
        case schema, acpxRecordId, acpSessionId, agentSessionId, agentCommand, agentArgv, cwd, name
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
        // `parseOptionalAgentArgv`: strings, at least one, the first not empty.
        agentArgv = (try? c.decodeIfPresent([String].self, forKey: .agentArgv)).flatMap { argv in
            argv.first.map { !$0.isEmpty } == true ? argv : nil
        }
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
        storedTitle = c.contains(.title) ? try c.decode(Nullable<String>.self, forKey: .title) : nil
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
        try c.encodeIfPresent(agentArgv, forKey: .agentArgv)
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
        try c.encodeIfPresent(storedTitle, forKey: .title)
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
    /// The last write's error: `null` on disk when there was none, as acpx builds the
    /// block (`defaultSessionEventLog`, and again on each write).
    public var lastWriteError: String? {
        get { storedLastWriteError?.value }
        set { storedLastWriteError = newValue.map(Nullable.value) ?? .null }
    }
    /// `lastWriteError` as written: absent only when the block was read without one, as
    /// acpx's `parseEventLog` keeps it, until the log is next written.
    private var storedLastWriteError: Nullable<String>? = .null

    enum CodingKeys: String, CodingKey {
        case activePath, segmentCount, maxSegmentBytes, maxSegments, lastWriteAt, lastWriteError
    }

    public init(recordId: String) {
        self.activePath = ACPXPaths.sessionStreamPath(recordId).path
        self.segmentCount = DEFAULT_EVENT_MAX_SEGMENTS
        self.maxSegmentBytes = DEFAULT_EVENT_SEGMENT_MAX_BYTES
        self.maxSegments = DEFAULT_EVENT_MAX_SEGMENTS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activePath = try c.decodeIfPresent(String.self, forKey: .activePath) ?? ""
        segmentCount = try c.decodeIfPresent(Int.self, forKey: .segmentCount) ?? DEFAULT_EVENT_MAX_SEGMENTS
        maxSegmentBytes =
            try c.decodeIfPresent(Int.self, forKey: .maxSegmentBytes) ?? DEFAULT_EVENT_SEGMENT_MAX_BYTES
        maxSegments = try c.decodeIfPresent(Int.self, forKey: .maxSegments) ?? DEFAULT_EVENT_MAX_SEGMENTS
        lastWriteAt = try c.decodeIfPresent(String.self, forKey: .lastWriteAt)
        storedLastWriteError =
            c.contains(.lastWriteError) ? try c.decode(Nullable<String>.self, forKey: .lastWriteError) : nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(activePath, forKey: .activePath)
        try c.encode(segmentCount, forKey: .segmentCount)
        try c.encode(maxSegmentBytes, forKey: .maxSegmentBytes)
        try c.encode(maxSegments, forKey: .maxSegments)
        try c.encodeIfPresent(lastWriteAt, forKey: .lastWriteAt)
        try c.encodeIfPresent(storedLastWriteError, forKey: .lastWriteError)
    }
}
