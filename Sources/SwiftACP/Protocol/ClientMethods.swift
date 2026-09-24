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

// The agent runs a command through the client and reads its output back, instead of
// running it itself. https://agentclientprotocol.com/protocol/v1/terminals
//
// Served by the ``ACPTerminalHandler`` a connection is given (``TerminalManager`` on
// macOS and Linux) when the client advertises `terminal: true`, as acpx does unless
// `--no-terminal` is given.

/// The agent asks the client to run a command in a new terminal (`terminal/create`).
public struct CreateTerminalRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var command: String
    /// The command's arguments. Absent, and the command may be a shell command line:
    /// acpx runs one that is not found as a program through the shell.
    public var args: [String]?
    public var cwd: String?
    public var env: [EnvVariable]?
    /// Maximum output bytes the client retains; earlier output is dropped beyond this.
    /// A fractional limit is rounded, as acpx's `Math.round` rounds it.
    public var outputByteLimit: Int?

    public init(
        sessionId: SessionId, command: String, args: [String]? = nil, cwd: String? = nil,
        env: [EnvVariable]? = nil, outputByteLimit: Int? = nil
    ) {
        self.sessionId = sessionId
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.outputByteLimit = outputByteLimit
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, command, args, cwd, env, outputByteLimit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(SessionId.self, forKey: .sessionId)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        env = try container.decodeIfPresent([EnvVariable].self, forKey: .env)
        // The schema's `number`: any one is taken, rounded half up like `Math.round`.
        outputByteLimit = try container.decodeIfPresent(Double.self, forKey: .outputByteLimit)
            .map { Self.javaScriptRounded($0) }
    }

    /// `Math.round`, saturated into `Int`'s range.
    static func javaScriptRounded(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        let rounded = (value + 0.5).rounded(.down)
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }
}

/// The id of the new terminal, used by all the other `terminal/*` methods.
public struct CreateTerminalResponse: Codable, Sendable {
    public var terminalId: String
    public init(terminalId: String) { self.terminalId = terminalId }
}

/// How a terminal command ended: its exit code, or the signal that killed it.
///
/// Both members are always sent, `null` when they do not apply, as acpx sends them.
public struct TerminalExitStatus: Codable, Sendable, Hashable {
    public var exitCode: Int?
    /// The signal's name, as Node reports it: `SIGTERM`, `SIGKILL`, …
    public var signal: String?
    public init(exitCode: Int? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }

    private enum CodingKeys: String, CodingKey { case exitCode, signal }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(signal, forKey: .signal)
    }
}

/// The agent polls the output a terminal has produced so far (`terminal/output`).
public struct TerminalOutputRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
    public init(sessionId: SessionId, terminalId: String) {
        self.sessionId = sessionId
        self.terminalId = terminalId
    }
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
    public init(sessionId: SessionId, terminalId: String) {
        self.sessionId = sessionId
        self.terminalId = terminalId
    }
}

/// The exit code or terminating signal of the finished command. Both members are
/// always sent, `null` when they do not apply, as acpx sends them.
public struct WaitForTerminalExitResponse: Codable, Sendable, Hashable {
    public var exitCode: Int?
    public var signal: String?
    public init(exitCode: Int? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }

    public init(_ status: TerminalExitStatus) {
        self.init(exitCode: status.exitCode, signal: status.signal)
    }

    private enum CodingKeys: String, CodingKey { case exitCode, signal }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(signal, forKey: .signal)
    }
}

/// The agent kills a terminal's command without releasing the terminal, so the
/// output produced so far can still be read (`terminal/kill`).
public struct KillTerminalRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
    public init(sessionId: SessionId, terminalId: String) {
        self.sessionId = sessionId
        self.terminalId = terminalId
    }
}

/// Empty acknowledgement that the command was killed.
public struct KillTerminalResponse: Codable, Sendable {
    public init() {}
}

/// The agent frees a terminal and its buffers, killing the command if it is
/// still running (`terminal/release`).
public struct ReleaseTerminalRequest: Codable, Sendable {
    public var sessionId: SessionId
    public var terminalId: String
    public init(sessionId: SessionId, terminalId: String) {
        self.sessionId = sessionId
        self.terminalId = terminalId
    }
}

/// Empty acknowledgement that the terminal was released.
public struct ReleaseTerminalResponse: Codable, Sendable {
    public init() {}
}
