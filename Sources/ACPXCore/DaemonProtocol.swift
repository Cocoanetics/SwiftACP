import Foundation
@_exported import SwiftACP

// The daemon's MCP tool DTOs — `TurnEndedEvent`, `SessionSummary`, `SessionDetail`,
// `PruneResult`, `HistoryEntry` — live in `SwiftACP` (alongside the `@MCPServer`
// `ACPXDaemon` shell), so the generated `ACPXDaemon.Client` decodes them on every
// platform. What stays in `ACPXCore` are the `init(record:)` convenience
// initializers, which project a persisted `SessionRecord` (a macOS-only type) into
// those portable DTOs.

extension SessionSummary {
    /// Project a persisted session record into a `listSessions` row.
    public init(record: SessionRecord) {
        self.init(
            id: record.acpxRecordId, sessionId: record.acpSessionId,
            agentCommand: record.agentCommand, cwd: record.cwd, name: record.name,
            closed: record.closed == true, lastUsedAt: record.lastUsedAt)
    }
}

extension SessionDetail {
    /// Project a persisted session record into a `showSession` detail.
    public init(record: SessionRecord) {
        self.init(
            id: record.acpxRecordId, sessionId: record.acpSessionId,
            agentSessionId: record.agentSessionId, agentCommand: record.agentCommand,
            cwd: record.cwd, name: record.name, createdAt: record.createdAt,
            lastUsedAt: record.lastUsedAt, lastPromptAt: record.lastPromptAt,
            closed: record.closed == true, closedAt: record.closedAt, pid: record.pid,
            agentStartedAt: record.agentStartedAt,
            lastAgentExitCode: record.lastAgentExitCode?.value,
            lastAgentExitSignal: record.lastAgentExitSignal?.value,
            lastAgentExitAt: record.lastAgentExitAt,
            lastAgentDisconnectReason: record.lastAgentDisconnectReason,
            historyEntries: SessionStore.conversationHistoryEntries(record).count)
    }
}
