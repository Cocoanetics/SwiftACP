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

public struct RequestPermissionResponse: Codable, Sendable {
    public var outcome: RequestPermissionOutcome
    public init(outcome: RequestPermissionOutcome) { self.outcome = outcome }

    /// The user (or policy) picked an option.
    public static func selected(_ optionId: String) -> RequestPermissionResponse {
        .init(outcome: .selected(optionId: optionId))
    }
    /// The turn was cancelled before a choice was made.
    public static var cancelled: RequestPermissionResponse {
        .init(outcome: .cancelled)
    }
}

public enum RequestPermissionOutcome: Codable, Sendable {
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
