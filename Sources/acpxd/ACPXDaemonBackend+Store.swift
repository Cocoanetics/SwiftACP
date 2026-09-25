import ACPXCore
import Foundation
import SwiftACP

/// The daemon's persisted-store tools — the read side (`listSessions`, `showSession`,
/// `sessionHistory`) plus `pruneSessions` — and the record-lookup helpers the live
/// session tools in `ACPXDaemonBackend.swift` share.
extension ACPXDaemonBackend {
    /// List persisted sessions (newest-first), optionally filtered to one agent —
    /// mirrors the CLI's `sessions list`.
    ///
    /// - Parameter agentCommand: keep only sessions for this agent. A short name
    ///   (e.g. `claude`) matches sessions created with either that name or its
    ///   expanded launch command. Blank / omitted = every session.
    func listSessions(agentCommand: String? = nil) -> [SessionSummary] {
        sessions(matchingAgent: agentCommand).map(SessionSummary.init)
    }

    /// Show one persisted session's details — mirrors the CLI's `sessions show`.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    func showSession(sessionId: String) throws -> SessionDetail {
        guard let record = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        return SessionDetail(record: record)
    }

    /// Return a session's conversation history (oldest-first) — mirrors the CLI's
    /// `sessions history`.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - limit: keep only the last N entries; 0 / omitted = all.
    func sessionHistory(sessionId: String, limit: Int? = nil) throws -> [SessionStore.HistoryEntry] {
        guard let record = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let all = SessionStore.conversationHistoryEntries(record)
        guard let limit, limit > 0 else { return all }
        return Array(all.suffix(limit))
    }

    /// Look up a persisted record by acpx record id, then by ACP session id.
    func findRecord(_ id: String) -> SessionRecord? {
        if let record = SessionStore.loadRecord(id) { return record }
        return SessionStore.listSessions().first {
            $0.acpSessionId == id || $0.acpxRecordId == id
        }
    }

    /// Trim a caller-supplied string, returning nil when it's blank — so an empty
    /// MCP text field counts as "not provided" rather than a real (empty) value.
    func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Persisted sessions matching an optional agent filter. A short name and its
    /// expanded registry command compare equal, so `claude` matches sessions
    /// created with either form. Blank / omitted returns every session.
    func sessions(matchingAgent rawFilter: String?) -> [SessionRecord] {
        let all = SessionStore.listSessions()
        guard let filter = nonBlank(rawFilter) else { return all }
        let target = canonicalAgent(filter)
        return all.filter { canonicalAgent($0.agentCommand) == target }
    }

    /// Resolve a short agent name (e.g. `claude`) to its registry launch command;
    /// pass through anything that's already a full or custom command.
    func canonicalAgent(_ value: String) -> String {
        AgentRegistry.command(for: value) ?? value
    }

    /// Delete closed sessions (optionally per-agent, optionally only those idle
    /// since `olderThanDays` ago), freeing their records — mirrors the CLI's
    /// `sessions prune`.
    ///
    /// - Parameters:
    ///   - agentCommand: restrict to one agent (short name or expanded command);
    ///     blank / omitted = all agents.
    ///   - olderThanDays: only prune sessions closed at least this many days ago.
    ///   - includeHistory: also delete each session's event-log / history files.
    ///   - dryRun: report what would be removed without deleting anything.
    func pruneSessions(
        agentCommand: String? = nil, olderThanDays: Int? = nil,
        includeHistory: Bool = false, dryRun: Bool = false
    ) async -> PruneResult {
        let records = sessions(matchingAgent: agentCommand)
        let cutoff = olderThanDays.map { isoString(Date().addingTimeInterval(-Double($0) * 86400)) }
        let candidates = records.filter { record in
            guard record.closed == true else { return false }
            guard let cutoff else { return true }
            return (record.closedAt ?? record.lastUsedAt) < cutoff
        }
        var bytesFreed = 0
        if !dryRun {
            for record in candidates {
                // Terminate any live agent before removing its record.
                forgetOwner(record.acpxRecordId)
                await evict(record.acpxRecordId)
                bytesFreed += SessionStore.deleteRecord(
                    record.acpxRecordId, includeHistory: includeHistory)
            }
        }
        return PruneResult(
            count: candidates.count, bytesFreed: bytesFreed, dryRun: dryRun,
            pruned: candidates.map(\.acpxRecordId))
    }
}
