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
        let messages = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { line -> WireJSON? in
                guard let message = WireJSON(parsing: String(decoding: line, as: UTF8.self)),
                      WireJSON.isACPMessage(message)
                else { return nil }
                return message
            }
        var replay = Replay(messages: messages)
        return messages.indices.compactMap { replay.entry(at: $0) }
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
