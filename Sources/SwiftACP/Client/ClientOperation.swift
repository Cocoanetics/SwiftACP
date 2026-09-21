import Foundation

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
}
