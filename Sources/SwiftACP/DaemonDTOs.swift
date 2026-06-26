import Foundation

// The acpx daemon's MCP tool DTOs — the structured wire types the `acpx` MCP server
// returns and streams. They live in this shared, iOS-capable library (rather than the
// macOS-only `ACPXCore`) so the generated `ACPXDaemon.Client` and an iOS MCP client
// can decode them. `ACPXCore` adds the `init(record:)` convenience initializers that
// map a persisted `SessionRecord` into these.

/// The turn's terminal event, streamed as a final MCP log notification.
///
/// The `runPrompt` tool result is the agent's aggregate response *text* (so an MCP
/// client gets the actual answer, not a status token). The stop reason is therefore
/// demoted to a streamed event: the daemon sends one ``TurnEndedEvent`` once the turn
/// ends, right after the last `session/update` and before the tool returns.
public struct TurnEndedEvent: Codable, Sendable {
    /// The raw ACP stop reason (e.g. `end_turn`, `refusal`, `cancelled`).
    public var stopReason: String

    public init(stopReason: String) {
        self.stopReason = stopReason
    }
}

/// One row of the daemon's `listSessions` result — the columns the CLI's
/// `sessions list` shows, as structured data.
public struct SessionSummary: Codable, Sendable {
    public var id: String
    public var sessionId: String
    public var agentCommand: String
    public var cwd: String
    public var name: String?
    public var closed: Bool
    public var lastUsedAt: String

    public init(
        id: String, sessionId: String, agentCommand: String, cwd: String,
        name: String?, closed: Bool, lastUsedAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.agentCommand = agentCommand
        self.cwd = cwd
        self.name = name
        self.closed = closed
        self.lastUsedAt = lastUsedAt
    }
}

/// The daemon's `showSession` result — the fields the CLI's `sessions show`
/// prints, as structured data.
public struct SessionDetail: Codable, Sendable {
    public var id: String
    public var sessionId: String
    public var agentSessionId: String?
    public var agentCommand: String
    public var cwd: String
    public var name: String?
    public var createdAt: String
    public var lastUsedAt: String
    public var lastPromptAt: String?
    public var closed: Bool
    public var closedAt: String?
    public var pid: Int?
    public var agentStartedAt: String?
    public var lastAgentExitCode: Int?
    public var lastAgentExitSignal: String?
    public var lastAgentExitAt: String?
    public var lastAgentDisconnectReason: String?
    public var historyEntries: Int

    public init(
        id: String, sessionId: String, agentSessionId: String?, agentCommand: String,
        cwd: String, name: String?, createdAt: String, lastUsedAt: String,
        lastPromptAt: String?, closed: Bool, closedAt: String?, pid: Int?,
        agentStartedAt: String?, lastAgentExitCode: Int?, lastAgentExitSignal: String?,
        lastAgentExitAt: String?, lastAgentDisconnectReason: String?, historyEntries: Int
    ) {
        self.id = id
        self.sessionId = sessionId
        self.agentSessionId = agentSessionId
        self.agentCommand = agentCommand
        self.cwd = cwd
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastPromptAt = lastPromptAt
        self.closed = closed
        self.closedAt = closedAt
        self.pid = pid
        self.agentStartedAt = agentStartedAt
        self.lastAgentExitCode = lastAgentExitCode
        self.lastAgentExitSignal = lastAgentExitSignal
        self.lastAgentExitAt = lastAgentExitAt
        self.lastAgentDisconnectReason = lastAgentDisconnectReason
        self.historyEntries = historyEntries
    }
}

/// The daemon's `pruneSessions` result — mirrors the CLI's `sessions prune`.
public struct PruneResult: Codable, Sendable {
    public var count: Int
    public var bytesFreed: Int
    public var dryRun: Bool
    public var pruned: [String]

    public init(count: Int, bytesFreed: Int, dryRun: Bool, pruned: [String]) {
        self.count = count
        self.bytesFreed = bytesFreed
        self.dryRun = dryRun
        self.pruned = pruned
    }
}

/// One row of the daemon's `sessionHistory` result (oldest-first) — a turn's role,
/// timestamp, and a short text preview.
public struct HistoryEntry: Codable, Sendable {
    public var role: String
    public var timestamp: String
    public var textPreview: String

    public init(role: String, timestamp: String, textPreview: String) {
        self.role = role
        self.timestamp = timestamp
        self.textPreview = textPreview
    }
}
