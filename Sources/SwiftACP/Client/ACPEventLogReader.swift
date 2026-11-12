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

    public init(_ url: URL) {
        self.url = url
    }

    /// The log's typed entries; throws only when the file cannot be read.
    public func entries() throws -> [ACPEventLogEntry] {
        Self.entries(in: try Data(contentsOf: url))
    }

    /// The typed entries of NDJSON `data`.
    public static func entries(in data: Data) -> [ACPEventLogEntry] {
        var replay = Replay()
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let message = WireJSON(parsing: String(decoding: line, as: UTF8.self)),
                  WireJSON.isACPMessage(message)
            else { continue }
            if let entry = replay.entry(for: message) {
                replay.entries.append(entry)
            }
        }
        return replay.entries
    }

    /// The requests still unanswered, so that a response is told apart by what it answers:
    /// the client's and the agent's ids are separate spaces and may coincide, so a
    /// response goes to the latest open request with its id.
    private struct Replay {
        var entries: [ACPEventLogEntry] = []
        private var open: [(id: JSONRPCID, isPrompt: Bool)] = []

        mutating func entry(for message: WireJSON) -> ACPEventLogEntry? {
            let id = message["id"].flatMap { try? $0.jsonValue.decoded(JSONRPCID.self) }
            if let method = message["method"]?.stringValue {
                return request(method, id: id, params: message["params"])
            }
            guard let id, let index = open.lastIndex(where: { $0.id == id }) else { return nil }
            guard open.remove(at: index).isPrompt else { return nil }
            if let result = message["result"] {
                return (try? result.jsonValue.decoded(PromptResponse.self)).map {
                    .promptResponse(id: id, response: $0)
                }
            }
            return message["error"].flatMap { try? $0.jsonValue.decoded(JSONRPCError.self) }.map {
                .promptError(id: id, error: $0)
            }
        }

        private mutating func request(_ method: String, id: JSONRPCID?, params: WireJSON?) -> ACPEventLogEntry? {
            switch (method, id) {
            case ("session/update", nil):
                guard let params, var notification = try? params.jsonValue.decoded(SessionNotification.self)
                else { return nil }
                notification.rawUpdate = params["update"]
                return .update(notification)
            case ("session/prompt", let id?):
                let request = params.flatMap { try? $0.jsonValue.decoded(PromptRequest.self) }
                open.append((id, request != nil))
                return request.map { .prompt(id: id, request: $0) }
            case (_, let id?):
                open.append((id, false))
                return nil
            default:
                return nil
            }
        }
    }
}
