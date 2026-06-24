import Foundation

/// Wire types shared between `acpxd` (the MCP daemon) and the `acpx` CLI's
/// daemon client, beyond the ACP `SessionNotification`s that carry the turn's
/// streamed updates.
///
/// The `runPrompt` tool result is the agent's aggregate response *text* (so an
/// MCP client gets the actual answer, not a status token). The turn's stop
/// reason is therefore demoted to a streamed event: the daemon sends one final
/// ``TurnEndedEvent`` as a log notification once the turn ends, right after the
/// last `session/update` and before the tool returns.
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

    public init(record: SessionRecord) {
        self.id = record.acpxRecordId
        self.sessionId = record.acpSessionId
        self.agentCommand = record.agentCommand
        self.cwd = record.cwd
        self.name = record.name
        self.closed = record.closed == true
        self.lastUsedAt = record.lastUsedAt
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

    public init(record: SessionRecord) {
        self.id = record.acpxRecordId
        self.sessionId = record.acpSessionId
        self.agentSessionId = record.agentSessionId
        self.agentCommand = record.agentCommand
        self.cwd = record.cwd
        self.name = record.name
        self.createdAt = record.createdAt
        self.lastUsedAt = record.lastUsedAt
        self.lastPromptAt = record.lastPromptAt
        self.closed = record.closed == true
        self.closedAt = record.closedAt
        self.pid = record.pid
        self.agentStartedAt = record.agentStartedAt
        self.lastAgentExitCode = record.lastAgentExitCode?.value
        self.lastAgentExitSignal = record.lastAgentExitSignal?.value
        self.lastAgentExitAt = record.lastAgentExitAt
        self.lastAgentDisconnectReason = record.lastAgentDisconnectReason
        self.historyEntries = SessionStore.conversationHistoryEntries(record).count
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
