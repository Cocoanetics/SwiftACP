import Foundation
import JSONFoundation

/// The ACP major protocol version. A single integer; this library speaks v1.
/// See https://agentclientprotocol.com/protocol/v1/initialization
public let ACP_PROTOCOL_VERSION = 1

/// Identifies a client or agent implementation in the handshake.
public struct Implementation: Codable, Hashable, Sendable {
    public var name: String
    public var version: String?
    public var title: String?

    public init(name: String, version: String? = nil, title: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
    }
}

// MARK: - Capabilities

/// What the client (this library / its host) can do for the agent.
public struct ClientCapabilities: Codable, Hashable, Sendable {
    public var fs: FileSystemCapability
    public var terminal: Bool

    public init(fs: FileSystemCapability = .init(), terminal: Bool = false) {
        self.fs = fs
        self.terminal = terminal
    }
}

public struct FileSystemCapability: Codable, Hashable, Sendable {
    public var readTextFile: Bool
    public var writeTextFile: Bool

    public init(readTextFile: Bool = false, writeTextFile: Bool = false) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
    }
}

/// What the agent advertises it can do. Unknown/omitted fields default to "off",
/// so we keep this permissive and decode only the parts we act on.
public struct AgentCapabilities: Codable, Hashable, Sendable {
    public var loadSession: Bool?
    public var promptCapabilities: PromptCapabilities?
    public var mcpCapabilities: JSONValue?
    public var sessionCapabilities: SessionCapabilities?

    public init(
        loadSession: Bool? = nil,
        promptCapabilities: PromptCapabilities? = nil,
        mcpCapabilities: JSONValue? = nil,
        sessionCapabilities: SessionCapabilities? = nil
    ) {
        self.loadSession = loadSession
        self.promptCapabilities = promptCapabilities
        self.mcpCapabilities = mcpCapabilities
        self.sessionCapabilities = sessionCapabilities
    }
}

/// Agent session-management capabilities (presence of a key indicates support).
public struct SessionCapabilities: Codable, Hashable, Sendable {
    public var resume: JSONValue?
    public var load: JSONValue?
    public var list: JSONValue?

    public var supportsResume: Bool { resume != nil }
    public var supportsLoad: Bool { load != nil }
    public var supportsList: Bool { list != nil }
}

public struct PromptCapabilities: Codable, Hashable, Sendable {
    public var image: Bool?
    public var audio: Bool?
    public var embeddedContext: Bool?

    public init(image: Bool? = nil, audio: Bool? = nil, embeddedContext: Bool? = nil) {
        self.image = image
        self.audio = audio
        self.embeddedContext = embeddedContext
    }
}

public struct AuthMethod: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var description: String?

    public init(id: String, name: String? = nil, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

// MARK: - initialize

public struct InitializeRequest: Codable, Sendable {
    public var protocolVersion: Int
    public var clientCapabilities: ClientCapabilities
    public var clientInfo: Implementation?

    public init(
        protocolVersion: Int = ACP_PROTOCOL_VERSION,
        clientCapabilities: ClientCapabilities,
        clientInfo: Implementation? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
    }
}

public struct InitializeResponse: Codable, Sendable {
    public var protocolVersion: Int
    public var agentCapabilities: AgentCapabilities?
    public var agentInfo: Implementation?
    public var authMethods: [AuthMethod]?

    public init(
        protocolVersion: Int = ACP_PROTOCOL_VERSION,
        agentCapabilities: AgentCapabilities? = nil,
        agentInfo: Implementation? = nil,
        authMethods: [AuthMethod]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.agentInfo = agentInfo
        self.authMethods = authMethods
    }
}

// MARK: - authenticate

public struct AuthenticateRequest: Codable, Sendable {
    public var methodId: String
    public init(methodId: String) { self.methodId = methodId }
}
