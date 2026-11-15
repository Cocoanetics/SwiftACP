import Foundation
import JSONFoundation

/// One typed message replayed from an ACP event log (``ACPEventLogReader``).
public enum ACPEventLogEntry: Sendable {
    /// A `session/prompt` request and its JSON-RPC id.
    case prompt(id: JSONRPCID, request: PromptRequest)
    /// The result answering the `session/prompt` with `id`.
    case promptResponse(id: JSONRPCID, response: PromptResponse)
    /// The JSON-RPC error answering the `session/prompt` with `id`.
    case promptError(id: JSONRPCID, error: JSONRPCError)
    /// A `session/update` notification, with ``SessionNotification/rawUpdate`` as written.
    case update(SessionNotification)
}

/// A typed entry with its physical position and optional local observation metadata.
public struct ACPEventLogTimedEntry: Sendable {
    public let entry: ACPEventLogEntry
    public let timestamp: Date?
    public let direction: ACPEventLogDirection?
    /// Zero-based byte offset in the raw log, including any preceding skipped lines.
    public let byteOffset: UInt64
}

/// An accepted ACP message, including messages omitted from typed replay.
public struct ACPEventLogTimedMessage: Sendable {
    public let message: WireJSON
    public let timestamp: Date?
    public let direction: ACPEventLogDirection?
    /// Zero-based byte offset in the raw log, stable even when observation times tie.
    public let byteOffset: UInt64
}

/// Replays an NDJSON event log — as ``ACPEventLogWriter`` appends it — into typed
/// `session/prompt`, prompt-answer and `session/update` entries, in file order.
///
/// Lines are split on the byte `\n` and kept when they parse as an ACP message
/// (``WireJSON/isACPMessage(_:)``), as `SessionArchive.history` reads them; anything else —
/// a partial last line from a write cut short included — is skipped, not a failure.
/// Other ACP messages (`initialize`, `session/new`, the agent's own requests, …) stay in
/// the file but are left out of the typed sequence.
public struct ACPEventLogReader: Sendable {
    private let url: URL
    private let timestampIndex: URL?

    /// The index is explicit; ordinary ``entries()`` never reads it.
    public init(_ url: URL, timestampIndex: URL? = nil) {
        self.url = url
        self.timestampIndex = timestampIndex
    }

    /// The log's typed entries; throws only when the file cannot be read.
    public func entries() throws -> [ACPEventLogEntry] {
        Self.entries(in: try Data(contentsOf: url))
    }

    /// The typed entries of NDJSON `data`.
    public static func entries(in data: Data) -> [ACPEventLogEntry] {
        let messages = parsedMessages(in: data).map(\.message)
        var replay = Replay(messages: messages)
        return messages.indices.compactMap { replay.entry(at: $0) }
    }

    /// Typed replay in file order. Only raw-log read failures throw; unusable index
    /// records leave metadata nil. The raw snapshot is read before the optional index.
    public func entriesWithTimes() throws -> [ACPEventLogTimedEntry] {
        let data = try Data(contentsOf: url)
        return Self.entriesWithTimes(in: data, timestampIndex: readIndex())
    }

    /// Typed replay of a raw snapshot and optional companion index snapshot.
    /// Direction is metadata only; request/response classification matches ``entries(in:)``.
    public static func entriesWithTimes(in data: Data, timestampIndex: Data? = nil) -> [ACPEventLogTimedEntry] {
        let messages = messagesWithTimes(in: data, timestampIndex: timestampIndex)
        var replay = Replay(messages: messages.map(\.message))
        return messages.indices.compactMap { index in
            guard let entry = replay.entry(at: index) else { return nil }
            let message = messages[index]
            return ACPEventLogTimedEntry(entry: entry, timestamp: message.timestamp,
                                         direction: message.direction, byteOffset: message.byteOffset)
        }
    }

    /// Every accepted ACP message in file order, including initialize and permission
    /// requests/replies. Times may tie or move backwards; replay never sorts by time.
    public func messagesWithTimes() throws -> [ACPEventLogTimedMessage] {
        let data = try Data(contentsOf: url)
        return Self.messagesWithTimes(in: data, timestampIndex: readIndex())
    }

    /// Raw replay of snapshots. A parseable final line without LF replays with nil
    /// metadata; incomplete raw or index tails are ignored. Legacy logs need no index.
    public static func messagesWithTimes(in data: Data, timestampIndex: Data? = nil) -> [ACPEventLogTimedMessage] {
        let records = indexRecords(in: timestampIndex)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parsedMessages(in: data).map { parsed in
            let offset = UInt64(parsed.bytes.startIndex - data.startIndex)
            var timestamp: Date?
            var direction: ACPEventLogDirection?
            if let record = records[offset], record.version == 1,
               parsed.bytes.last == 0x0A, record.length == UInt64(parsed.bytes.count),
               record.crc32 == ACPEventLogIndexRecord.checksum(parsed.bytes),
               record.timestamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#,
                                      options: .regularExpression) != nil,
               let date = formatter.date(from: record.timestamp),
               formatter.string(from: date) == record.timestamp {
                timestamp = date
                direction = record.direction
            }
            return ACPEventLogTimedMessage(message: parsed.message, timestamp: timestamp,
                                           direction: direction, byteOffset: offset)
        }
    }

    private func readIndex() -> Data? {
        timestampIndex.flatMap { try? Data(contentsOf: $0) }
    }

    /// Slice before filtering, retaining the physical line (including LF when present).
    /// Exact slice-length matching validates bounds, both boundaries and a single line
    /// without arithmetic on untrusted UInt64 offsets/lengths or searching by body text.
    private static func parsedMessages(in data: Data) -> [(message: WireJSON, bytes: Data)] {
        data.split(separator: 0x0A, omittingEmptySubsequences: false).compactMap { line in
            guard let message = WireJSON(parsing: String(decoding: line, as: UTF8.self)),
                  WireJSON.isACPMessage(message) else { return nil }
            let end = line.endIndex < data.endIndex ? line.endIndex + 1 : line.endIndex
            return (message, data[line.startIndex..<end])
        }
    }

    private struct IndexOffset: Decodable {
        let offset: UInt64
    }

    /// Conflicts poison only their exact offset, including syntactically invalid records
    /// whose offset can still be decoded. Only complete, LF-terminated records count.
    private static func indexRecords(in data: Data?) -> [UInt64: ACPEventLogIndexRecord] {
        guard let data else { return [:] }
        let decoder = JSONDecoder()
        var records: [UInt64: ACPEventLogIndexRecord] = [:]
        var invalid: Set<UInt64> = []
        for line in data.split(separator: 0x0A) where line.endIndex < data.endIndex {
            guard let offset = try? decoder.decode(IndexOffset.self, from: line).offset else { continue }
            guard let record = try? decoder.decode(ACPEventLogIndexRecord.self, from: line),
                  records[offset] == nil || records[offset] == record else {
                invalid.insert(offset)
                continue
            }
            records[offset] = record
        }
        for offset in invalid { records[offset] = nil }
        return records
    }

    /// The requests still unanswered, by side. The log does not say which peer wrote a
    /// message, and the client's and the agent's ids are separate spaces that may
    /// coincide, so a request's side is told by its method (``agentMethod(_:)``) or by its
    /// id being one of the client's open ones, and a
    /// response's, when its id is open on both, by what it answers (``answersClient(at:)``).
    private struct Replay {
        let messages: [WireJSON]
        /// The client's open requests by id: whether each is a `session/prompt` replayed.
        private var client: [JSONRPCID: Bool] = [:]
        private var agent: Set<JSONRPCID> = []

        init(messages: [WireJSON]) {
            self.messages = messages
        }

        mutating func entry(at index: Int) -> ACPEventLogEntry? {
            let message = messages[index]
            let id = Self.id(of: message)
            if let method = message["method"]?.stringValue {
                return request(method, id: id, params: message["params"])
            }
            guard let id else { return nil }
            if let isPrompt = client[id], !agent.contains(id) || answersClient(at: index) {
                client[id] = nil
                return isPrompt ? Self.promptAnswer(message, id: id) : nil
            }
            agent.remove(id)
            return nil
        }

        /// Whether the response at `index`, whose id both sides have open, answers the
        /// client's request: a result that is a `PromptResponse` does; any other result
        /// answers the agent's. An error is the client's when the other answer to that id
        /// later in the log is not a `PromptResponse` (the agent's request answered after
        /// the prompt failed), else the agent's — as it is when no other answer follows.
        private func answersClient(at index: Int) -> Bool {
            let message = messages[index]
            if message["result"] != nil { return Self.isPromptResponse(message) }
            let id = Self.id(of: message)
            guard let next = messages[(index + 1)...].first(where: {
                $0["method"] == nil && Self.id(of: $0) == id
            }) else { return false }
            return !Self.isPromptResponse(next)
        }

        private mutating func request(_ method: String, id: JSONRPCID?, params: WireJSON?) -> ACPEventLogEntry? {
            switch (method, id) {
            case ("session/update", nil):
                guard let params, var notification = try? params.jsonValue.decoded(SessionNotification.self)
                else { return nil }
                notification.rawUpdate = params["update"]
                return .update(notification)
            // A peer does not reuse an id it has open, so a request with the id of one of the
            // client's open requests is the agent's — an `_` extension method, say.
            case (_, let id?) where Self.agentMethod(method) || client[id] != nil:
                agent.insert(id)
                return nil
            case ("session/prompt", let id?):
                let request = params.flatMap { try? $0.jsonValue.decoded(PromptRequest.self) }
                client[id] = request != nil
                return request.map { .prompt(id: id, request: $0) }
            case (_, let id?):
                client[id] = false
                return nil
            default:
                return nil
            }
        }

        /// The ACP methods the agent calls on the client.
        private static func agentMethod(_ method: String) -> Bool {
            method == "session/request_permission" || method.hasPrefix("fs/") || method.hasPrefix("terminal/")
        }

        private static func id(of message: WireJSON) -> JSONRPCID? {
            message["id"].flatMap { try? $0.jsonValue.decoded(JSONRPCID.self) }
        }

        private static func isPromptResponse(_ message: WireJSON) -> Bool {
            message["result"].map { (try? $0.jsonValue.decoded(PromptResponse.self)) != nil } ?? false
        }

        private static func promptAnswer(_ message: WireJSON, id: JSONRPCID) -> ACPEventLogEntry? {
            if let result = message["result"] {
                return (try? result.jsonValue.decoded(PromptResponse.self)).map {
                    .promptResponse(id: id, response: $0)
                }
            }
            return message["error"].flatMap { try? $0.jsonValue.decoded(JSONRPCError.self) }.map {
                .promptError(id: id, error: $0)
            }
        }
    }
}
