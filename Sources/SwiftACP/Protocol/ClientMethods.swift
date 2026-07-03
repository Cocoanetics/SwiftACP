import Foundation

// MARK: - fs/read_text_file, fs/write_text_file

// The agent delegates file access to the client so the client stays in control
// of what is read and written. https://agentclientprotocol.com/protocol/v1/file-system

/// The agent asks the client to read a text file, optionally windowed to a
/// 1-based starting `line` and a `limit` on the number of lines returned.
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

/// The file (or the requested window of it) as a single string.
public struct ReadTextFileResponse: Codable, Sendable {
    public var content: String
    public init(content: String) { self.content = content }
}

/// The agent asks the client to write `content` to a file, creating it if needed.
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

/// Empty acknowledgement that the write succeeded.
public struct WriteTextFileResponse: Codable, Sendable {
    public init() {}
}

// MARK: - terminal/*

// Modelled for completeness. This client advertises `terminal: false` by
// default (a headless controller lets the agent run its own commands), so these
// are only used if terminal support is explicitly enabled.

/// The agent asks the client to run a command in a new terminal (`terminal/create`).
public struct CreateTerminalRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var command: String
    public var args: [String]?
    public var cwd: String?
    public var env: [EnvVariable]?
    /// Maximum output bytes the client retains; earlier output is dropped beyond this.
    public var outputByteLimit: Int?
}

/// The id of the new terminal, used by all the other `terminal/*` methods.
public struct CreateTerminalResponse: Codable, Sendable {
    public var terminalId: String
    public init(terminalId: String) { self.terminalId = terminalId }
}

/// How a terminal command ended: its exit code and/or the signal that killed it.
public struct TerminalExitStatus: Codable, Sendable {
    public var exitCode: Int?
    public var signal: String?
    public init(exitCode: Int? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }
}

/// The agent polls the output a terminal has produced so far (`terminal/output`).
public struct TerminalOutputRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
}

/// Output captured so far, whether the byte limit truncated it, and — once the
/// command has ended — its exit status.
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

/// The agent blocks until a terminal's command exits (`terminal/wait_for_exit`).
public struct WaitForTerminalExitRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
}

/// The exit code and/or terminating signal of the finished command.
public struct WaitForTerminalExitResponse: Codable, Sendable {
    public var exitCode: Int?
    public var signal: String?
    public init(exitCode: Int? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }
}

/// The agent kills a terminal's command without releasing the terminal, so the
/// output produced so far can still be read (`terminal/kill`).
public struct KillTerminalRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
}

/// The agent frees a terminal and its buffers, killing the command if it is
/// still running (`terminal/release`).
public struct ReleaseTerminalRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
}
