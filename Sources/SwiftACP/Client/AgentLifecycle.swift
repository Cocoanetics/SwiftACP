import Foundation

/// What ended an agent's connection — acpx's `AgentDisconnectReason`. acpx's client
/// watches the process's `exit` and `close` and its stdout's `close`, besides the
/// connection itself; the first to report is what the agent's end is put down to.
public enum AgentDisconnectReason: String, Sendable, Equatable, Codable {
    /// The process exited.
    case processExit = "process_exit"
    /// The process exited and its stdio closed. Node reports this after `exit`, so it
    /// wins only when that went unseen.
    case processClose = "process_close"
    /// Its stdout closed while it still ran.
    case pipeClose = "pipe_close"
    /// The connection ended for another reason — a message too long, say.
    case connectionClose = "connection_close"
}

/// How an agent's process ended, as acpx records it (`AgentExitInfo`): the first
/// observer's account wins.
public struct AgentExit: Sendable, Equatable {
    /// Its exit code, `nil` if a signal ended it or it had not exited yet.
    public let exitCode: Int?
    /// The signal that ended it, by name (`SIGTERM`).
    public let signal: String?
    /// When the end was recorded, in acpx's ISO 8601 form.
    public let exitedAt: String
    public let reason: AgentDisconnectReason
    /// Whether it ended while a prompt ran and nothing was closing it.
    public let unexpectedDuringPrompt: Bool

    public init(
        exitCode: Int?, signal: String?, exitedAt: String, reason: AgentDisconnectReason,
        unexpectedDuringPrompt: Bool
    ) {
        self.exitCode = exitCode
        self.signal = signal
        self.exitedAt = exitedAt
        self.reason = reason
        self.unexpectedDuringPrompt = unexpectedDuringPrompt
    }
}

/// An agent's process as acpx reports it (`AgentLifecycleSnapshot`): what the session
/// record keeps of it (`pid`, `agent_started_at`, `last_agent_exit_*`).
public struct AgentLifecycleSnapshot: Sendable, Equatable {
    public let pid: Int32?
    /// When it was started, in acpx's ISO 8601 form.
    public let startedAt: String?
    public let running: Bool
    public let lastExit: AgentExit?

    public init(pid: Int32?, startedAt: String?, running: Bool, lastExit: AgentExit?) {
        self.pid = pid
        self.startedAt = startedAt
        self.running = running
        self.lastExit = lastExit
    }
}

/// acpx's `AgentDisconnectedError`: the agent's connection ended while a request
/// waited for its answer. acpx reports it as `RUNTIME`, detail code
/// `AGENT_DISCONNECTED`, from `acp`.
public struct AgentDisconnectedError: LocalizedError, Sendable, Equatable {
    public let reason: AgentDisconnectReason
    public let exitCode: Int?
    public let signal: String?

    public init(reason: AgentDisconnectReason, exitCode: Int?, signal: String?) {
        self.reason = reason
        self.exitCode = exitCode
        self.signal = signal
    }

    public var errorDescription: String? {
        "ACP agent disconnected during request (\(reason.rawValue), \(exitSummary(exitCode, signal)))"
    }
}

/// acpx's `AgentStartupError`: the agent exited before `initialize` (and any
/// `authenticate`) completed — with the end of what it printed on stderr, which says
/// why. acpx reports it as `RUNTIME`, detail code `AGENT_STARTUP_FAILED`, from `acp`.
public struct AgentStartupError: LocalizedError, Sendable, Equatable {
    /// The command the agent was started with.
    public let agentCommand: String
    public let exitCode: Int?
    public let signal: String?
    /// Its stderr, whitespace collapsed — the last 8,192 characters of it.
    public let stderrSummary: String?

    public init(agentCommand: String, exitCode: Int?, signal: String?, stderrSummary: String?) {
        self.agentCommand = agentCommand
        self.exitCode = exitCode
        self.signal = signal
        let summary = stderrSummary?.trimmedLikeJavaScript
        self.stderrSummary = summary?.isEmpty == false ? summary : nil
    }

    public var errorDescription: String? {
        "ACP agent exited before initialize completed (\(exitSummary(exitCode, signal)))"
            + (stderrSummary.map { ": \($0)" } ?? "")
    }
}

/// The agent's stderr as acpx keeps it for a startup failure (`captureStartupStderr`):
/// each chunk decoded on its own, and only the last 8,192 characters (UTF-16 units)
/// of it all.
struct StderrTail {
    static let limit = 8192
    private var text: [UInt16] = []

    mutating func append(_ bytes: [UInt8]) {
        let chunk = String(decoding: bytes, as: UTF8.self)
        guard !chunk.isEmpty else { return }
        text += chunk.utf16
        if text.count > Self.limit { text.removeFirst(text.count - Self.limit) }
    }

    /// acpx's `summarizeStartupStderr`: trimmed, each run of whitespace one space, at
    /// most 8,192 characters; `nil` when there is nothing.
    var summary: String? {
        let joined = String(decoding: text, as: UTF16.self).trimmedLikeJavaScript
        guard !joined.isEmpty else { return nil }
        let collapsed = joined.unicodeScalars.split(whereSeparator: TerminalOutputLimit.isJavaScriptWhitespace)
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
        return String(decoding: Array(collapsed.utf16.prefix(Self.limit)), as: UTF16.self)
    }
}

private func exitSummary(_ exitCode: Int?, _ signal: String?) -> String {
    "exit=\(exitCode.map(String.init) ?? "null"), signal=\(signal ?? "null")"
}

/// acpx's `AcpMessageLimitError`: the agent wrote a line longer than
/// ``AcpMessageLimit`` allows. acpx reports it as `RUNTIME`, detail code
/// `ACP_MESSAGE_TOO_LARGE`, from `acp`, not retryable — and ends the connection.
public struct AcpMessageLimitError: LocalizedError, Sendable, Equatable {
    public let limit: Int

    public init(limit: Int) {
        self.limit = limit
    }

    public var errorDescription: String? {
        "ACP message exceeded ACPX_MAX_ACP_MESSAGE_BYTES (\(limit) bytes). "
            + "Increase the limit or set it to 0 for unlimited input."
    }
}

/// The longest line acpx reads from an agent: `ACPX_MAX_ACP_MESSAGE_BYTES`, 64 MiB when
/// unset, `0` for no limit.
public enum AcpMessageLimit {
    public static let defaultBytes = 64 * 1024 * 1024

    /// acpx's `readMaxAcpMessageBytes`: the variable trimmed; blank or unset is
    /// ``defaultBytes``; otherwise decimal digits naming a safe integer, `0` being no
    /// limit (`nil`). Anything else is refused with ``AcpMessageLimitSettingError``,
    /// as acpx refuses to start an agent under it.
    public static func bytes(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Int? {
        let trimmed = TerminalOutputLimit.javaScriptTrimmed(environment["ACPX_MAX_ACP_MESSAGE_BYTES"] ?? "")
        guard !trimmed.isEmpty else { return defaultBytes }
        guard let bytes = TerminalOutputLimit.nonNegativeSafeInteger(trimmed) else {
            throw AcpMessageLimitSettingError()
        }
        return bytes == 0 ? nil : bytes
    }
}

/// `ACPX_MAX_ACP_MESSAGE_BYTES` is not a non-negative safe integer. acpx will not start
/// an agent under it; the message is its own.
public struct AcpMessageLimitSettingError: LocalizedError, Equatable, Sendable, CustomStringConvertible {
    public init() {}

    public var description: String {
        "ACPX_MAX_ACP_MESSAGE_BYTES must be a non-negative safe integer; zero is unlimited"
    }

    public var errorDescription: String? { description }
}
