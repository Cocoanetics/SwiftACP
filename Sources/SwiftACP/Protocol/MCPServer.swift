import Foundation
import JSONFoundation

/// A name/value environment variable passed to a spawned MCP server or terminal.
public struct EnvVariable: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// An MCP server the agent should connect to for the session.
///
/// ACP supports stdio, HTTP and SSE MCP servers. The stdio form is modelled in
/// full; the network forms are kept as raw JSON since they are rarely needed
/// when driving a coding agent headlessly.
public enum MCPServerSpec: Codable, Hashable, Sendable {
    case stdio(StdioMCPServer)
    case other(JSONValue)

    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        // The discriminator is optional in older agents; absence implies stdio.
        if let container = try? decoder.container(keyedBy: TypeKey.self),
            let type = try? container.decodeIfPresent(String.self, forKey: .type),
            type != "stdio" {
            self = .other(try JSONValue(from: decoder))
            return
        }
        self = .stdio(try StdioMCPServer(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .stdio(let value): try value.encode(to: encoder)
        case .other(let value): try value.encode(to: encoder)
        }
    }
}

public struct StdioMCPServer: Codable, Hashable, Sendable {
    public var type = "stdio"
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [EnvVariable]

    public init(name: String, command: String, args: [String] = [], env: [EnvVariable] = []) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }
}
