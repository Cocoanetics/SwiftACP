import Foundation

// MARK: - fs/read_text_file, fs/write_text_file

// The agent delegates file access to the client so the client stays in control
// of what is read and written. https://agentclientprotocol.com/protocol/v1/file-system

public struct ReadTextFileRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var path: String
    public var line: Int?
    public var limit: Int?

    public init(sessionId: SessionId, path: String, line: Int? = nil, limit: Int? = nil) {
        self.sessionId = sessionId
        self.path = path
        self.line = line
        self.limit = limit
    }
}

public struct ReadTextFileResponse: Codable, Sendable {
    public var content: String
    public init(content: String) { self.content = content }
}

public struct WriteTextFileRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var path: String
    public var content: String

    public init(sessionId: SessionId, path: String, content: String) {
        self.sessionId = sessionId
        self.path = path
        self.content = content
    }
}

public struct WriteTextFileResponse: Codable, Sendable {
    public init() {}
}

// MARK: - terminal/*

// Modelled for completeness. This client advertises `terminal: false` by
// default (a headless controller lets the agent run its own commands), so these
// are only used if terminal support is explicitly enabled.

public struct CreateTerminalRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var command: String
    public var args: [String]?
    public var cwd: String?
    public var env: [EnvVariable]?
    public var outputByteLimit: Int?
}

public struct CreateTerminalResponse: Codable, Sendable {
    public var terminalId: String
    public init(terminalId: String) { self.terminalId = terminalId }
}

public struct TerminalExitStatus: Codable, Sendable {
    public var exitCode: Int?
    public var signal: String?
    public init(exitCode: Int? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }
}

public struct TerminalOutputRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
}

public struct TerminalOutputResponse: Codable, Sendable {
    public var output: String
    public var truncated: Bool
    public var exitStatus: TerminalExitStatus?
    public init(output: String, truncated: Bool, exitStatus: TerminalExitStatus? = nil) {
        self.output = output
        self.truncated = truncated
        self.exitStatus = exitStatus
    }
}

public struct WaitForTerminalExitRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
}

public struct WaitForTerminalExitResponse: Codable, Sendable {
    public var exitCode: Int?
    public var signal: String?
    public init(exitCode: Int? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }
}

public struct KillTerminalRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
}

public struct ReleaseTerminalRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
}
