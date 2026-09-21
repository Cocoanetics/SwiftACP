import Foundation
import JSONFoundation

/// The agent asks the client to approve a tool call.
/// https://agentclientprotocol.com/protocol/v1/tool-calls#requesting-permission
public struct RequestPermissionRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var toolCall: ToolCallUpdate
    public var options: [PermissionOption]

    public init(sessionId: SessionId, toolCall: ToolCallUpdate, options: [PermissionOption]) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
    }
}

/// One answer the agent offers for a permission request (e.g. "Allow once").
public struct PermissionOption: Codable, Sendable, Hashable {
    public var optionId: String
    public var name: String
    public var kind: PermissionOptionKind

    public init(optionId: String, name: String, kind: PermissionOptionKind) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }
}

/// The client's decision on a permission request.
public struct RequestPermissionResponse: Codable, Sendable {
    public var outcome: RequestPermissionOutcome
    /// Extension metadata riding on the response (`_meta`). The client attaches
    /// `acpx.permissionNotice` here when the refusal it chose may end the turn —
    /// see ``permissionNotice`` and ``CodexCompat``.
    public var meta: JSONValue?

    public init(outcome: RequestPermissionOutcome, meta: JSONValue? = nil) {
        self.outcome = outcome
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case meta = "_meta"
    }

    /// The user (or policy) picked an option.
    public static func selected(_ optionId: String) -> RequestPermissionResponse {
        .init(outcome: .selected(optionId: optionId))
    }
    /// The turn was cancelled before a choice was made.
    public static var cancelled: RequestPermissionResponse {
        .init(outcome: .cancelled)
    }
}

// MARK: - acpx response metadata

extension RequestPermissionResponse {
    /// A copy with `entries` merged into the response's `_meta.acpx` object, keeping
    /// every other `_meta` key and any `acpx` entries already present — a port of
    /// acpx's `withPermissionMetadata`.
    public func addingACPXMetadata(_ entries: [String: JSONValue]) -> RequestPermissionResponse {
        var meta = self.meta?.dictionaryValue ?? [:]
        var acpx = meta["acpx"]?.dictionaryValue ?? [:]
        acpx.merge(entries) { _, new in new }
        meta["acpx"] = .object(acpx)
        var copy = self
        copy.meta = .object(meta)
        return copy
    }

    /// The explanation the client attached under `_meta.acpx.permissionNotice` when
    /// the refusal it chose may end the turn (see ``CodexCompat``), or `nil` — a port
    /// of acpx's `parsePermissionNotice`.
    public var permissionNotice: String? {
        meta?["acpx"]?["permissionNotice"]?.stringValue
    }
}

/// How a permission request resolved: an option was selected, or the turn was
/// cancelled before a choice was made.
public enum RequestPermissionOutcome: Codable, Sendable, Hashable {
    case cancelled
    case selected(optionId: String)

    private enum Keys: String, CodingKey { case outcome, optionId }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .outcome) {
        case "selected":
            self = .selected(optionId: try container.decode(String.self, forKey: .optionId))
        default:
            self = .cancelled
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .cancelled:
            try container.encode("cancelled", forKey: .outcome)
        case .selected(let optionId):
            try container.encode("selected", forKey: .outcome)
            try container.encode(optionId, forKey: .optionId)
        }
    }
}
