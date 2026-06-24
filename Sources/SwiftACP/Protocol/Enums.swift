import Foundation

/// A string-backed enum that tolerates values it doesn't recognise.
///
/// ACP evolves by adding new enum cases without bumping the major version, so a
/// strict Swift `enum` would fail to decode a newer agent's output. These open
/// enums decode any string and expose well-known values as static members.
public protocol OpenStringEnum:
    RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

extension OpenStringEnum {
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
}

/// Why a prompt turn ended. https://agentclientprotocol.com/protocol/v1/prompt-turn
public struct StopReason: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let endTurn: StopReason = "end_turn"
    public static let maxTokens: StopReason = "max_tokens"
    public static let maxTurnRequests: StopReason = "max_turn_requests"
    public static let refusal: StopReason = "refusal"
    public static let cancelled: StopReason = "cancelled"
}

/// Lifecycle of a tool call. https://agentclientprotocol.com/protocol/v1/tool-calls
public struct ToolCallStatus: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let pending: ToolCallStatus = "pending"
    public static let inProgress: ToolCallStatus = "in_progress"
    public static let completed: ToolCallStatus = "completed"
    public static let failed: ToolCallStatus = "failed"
}

/// The high-level kind of a tool call, used by clients to pick an icon/treatment.
public struct ToolKind: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let read: ToolKind = "read"
    public static let edit: ToolKind = "edit"
    public static let delete: ToolKind = "delete"
    public static let move: ToolKind = "move"
    public static let search: ToolKind = "search"
    public static let execute: ToolKind = "execute"
    public static let think: ToolKind = "think"
    public static let fetch: ToolKind = "fetch"
    public static let other: ToolKind = "other"
}

/// Status of a single plan entry. https://agentclientprotocol.com/protocol/v1/agent-plan
public struct PlanEntryStatus: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let pending: PlanEntryStatus = "pending"
    public static let inProgress: PlanEntryStatus = "in_progress"
    public static let completed: PlanEntryStatus = "completed"
}

public struct PlanEntryPriority: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let high: PlanEntryPriority = "high"
    public static let medium: PlanEntryPriority = "medium"
    public static let low: PlanEntryPriority = "low"
}

/// The kind of a permission option offered by the agent.
public struct PermissionOptionKind: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let allowOnce: PermissionOptionKind = "allow_once"
    public static let allowAlways: PermissionOptionKind = "allow_always"
    public static let rejectOnce: PermissionOptionKind = "reject_once"
    public static let rejectAlways: PermissionOptionKind = "reject_always"
}
