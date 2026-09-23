import Foundation
import JSONFoundation

/// A client-side operation the connection performed on the agent's behalf, reported
/// for diagnostics — a port of acpx's `ClientOperation` (the `onClientOperation`
/// event its embedded runtimes receive).
///
/// The connection emits one when it answers a `session/request_permission` with a
/// refusal that may end the turn (see ``CodexCompat``): `status` is `completed` and
/// `summary` is the notice. Subscribers receive it in wire order as
/// ``ConnectionEvent/clientOperation(_:)``; `acpxd` streams it on to its MCP client
/// as a log notification, and the `acpx` CLI renders it as `[permission] …`.
public struct ClientOperation: Codable, Sendable, Hashable {
    /// The client-side ACP method, e.g. ``requestPermission``.
    public var method: String
    public var status: ClientOperationStatus
    /// One line for the user — for a permission notice, the explanation itself.
    public var summary: String
    /// Optional multi-line detail rendered under the summary.
    public var details: String?
    /// When the operation was reported: ISO 8601 with millisecond precision and a
    /// `Z` suffix, the JavaScript `toISOString()` shape acpx stamps its events with.
    public var timestamp: String
    /// The session the operation concerns, when it concerns one. Not part of acpx's
    /// shape; it lets a session-scoped consumer filter a shared connection's events.
    public var sessionId: SessionId?

    public init(
        method: String, status: ClientOperationStatus, summary: String, details: String? = nil,
        timestamp: String = ClientOperation.isoNow(), sessionId: SessionId? = nil
    ) {
        self.method = method
        self.status = status
        self.summary = summary
        self.details = details
        self.timestamp = timestamp
        self.sessionId = sessionId
    }

    /// The method a permission notice is reported under.
    public static let requestPermission = "session/request_permission"

    /// The current time in the ``timestamp`` format.
    public static func isoNow() -> String { isoFormatter.string(from: Date()) }
}

// ISO8601DateFormatter is documented thread-safe for formatting.
private nonisolated(unsafe) let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// The status of a ``ClientOperation`` (an open enum, like the protocol's).
public struct ClientOperationStatus: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let running: ClientOperationStatus = "running"
    public static let completed: ClientOperationStatus = "completed"
    public static let failed: ClientOperationStatus = "failed"
}

/// One event on an ``ACPAgentConnection`` event subscription, in wire order: an
/// agent `session/update`, or a client-side operation the connection reported.
public enum ConnectionEvent: Sendable {
    case update(SessionNotification)
    case clientOperation(ClientOperation)
    /// A request the agent made of this client, as it arrived or as it was refused.
    case inboundRequest(InboundRequest)
}

/// A request the agent made of this client — `fs/read_text_file`, `fs/write_text_file`,
/// `session/request_permission` — reported as it arrives, and again with ``failure``
/// if the client refused it.
///
/// acpx's formatter prints every request and every error it sees on the wire, which
/// shows up as `[client] fs/write_text_file (running)` and
/// `[error] RUNTIME: Permission denied for fs/write_text_file`. These carry those two
/// facts through the same event stream as the session's updates, so an update the
/// agent sent before a request is always seen before it, and a refusal always after
/// its request. (The JSON-RPC peer delivers notifications inline but dispatches each
/// request on its own task, so an update sent *after* a request, without awaiting its
/// reply, may be seen before the request. Agents await `fs/*` and permission
/// requests, so in practice this is wire order.)
///
/// Encoded with `inboundMethod` rather than `method` so it cannot be mistaken for a
/// ``ClientOperation`` where both travel as untyped JSON (the daemon's log stream).
public struct InboundRequest: Codable, Sendable, Hashable {
    public var method: String
    public var sessionId: SessionId?
    /// Why the client refused it, or `nil` for the request arriving — see
    /// ``summary(of:)``.
    public var failure: String?

    public init(method: String, sessionId: SessionId? = nil, failure: String? = nil) {
        self.method = method
        self.sessionId = sessionId
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case method = "inboundMethod"
        case sessionId, failure
    }

    /// acpx's `parseJsonRpcErrorSummary`: an error's `data.details` when it is a
    /// non-blank string — where a thrown handler error carries its real reason — else
    /// its message.
    public static func summary(of error: JSONRPCErrorBody) -> String {
        if case .object(let data)? = error.data, case .string(let details)? = data["details"] {
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return error.message
    }
}
