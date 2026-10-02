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
    /// - Parameter sessionId: the acpx record id or the ACP session id (``resolveRecord(_:)``).
    func showSession(sessionId: String) throws -> SessionDetail {
        SessionDetail(record: try resolveRecord(sessionId))
    }

    /// Return a session's conversation history (oldest-first) — mirrors the CLI's
    /// `sessions history`.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id (``resolveRecord(_:)``).
    ///   - limit: keep only the last N entries; 0 / omitted = all.
    func sessionHistory(sessionId: String, limit: Int? = nil) throws -> [SessionStore.HistoryEntry] {
        let all = SessionStore.conversationHistoryEntries(try resolveRecord(sessionId))
        guard let limit, limit > 0 else { return all }
        return Array(all.suffix(limit))
    }

    /// The persisted record `sessionId` names, as acpx's `resolveSessionRecord` finds it: the
    /// record filed under that id — one file read, no scan — else the one record whose id or ACP
    /// session id is `sessionId`, else the one record whose id or ACP session id ends with it.
    /// Two exact matches refuse the id, as records with ids of their own can share an agent's
    /// session (#307); so do two suffix matches; and none is not found (#301). A blank id is
    /// refused first: acpx never resolves one, its owner refusing it at input validation
    /// (`owner-input.ts`, `sessionId.trim().length === 0`), and every id ends with the empty
    /// string, which would hand a blank id the store's sole record.
    func resolveRecord(_ sessionId: String) throws -> SessionRecord {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DaemonError.emptySessionId
        }
        if let record = SessionStore.loadRecord(sessionId) { return record }
        var exact: [SessionRecord] = []
        var suffix: [SessionRecord] = []
        for record in SessionStore.scanRecords() {
            let ids = [record.acpxRecordId, record.acpSessionId]
            if ids.contains(where: { Self.sameUnits($0, sessionId) }) { Self.retainMatch(&exact, record) }
            if ids.contains(where: { Self.endsWithUnits($0, sessionId) }) { Self.retainMatch(&suffix, record) }
        }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw DaemonError.multipleSessionsMatch(sessionId) }
        if suffix.count == 1 { return suffix[0] }
        if suffix.count > 1 { throw DaemonError.ambiguousSessionId(sessionId) }
        throw DaemonError.sessionNotFound(sessionId)
    }

    /// JS `===` on the ids: equal UTF-16 code units. Swift's `==` compares by canonical
    /// equivalence, which would let a caller's id in another normalization form — `e` plus a
    /// combining accent for a record's precomposed `é` — match a record acpx would not find; the
    /// file fast path cannot, since ``ACPXPaths/safeSessionId(_:)`` percent-encodes each byte.
    private static func sameUnits(_ id: String, _ sessionId: String) -> Bool {
        id.utf16.elementsEqual(sessionId.utf16)
    }

    /// JS `endsWith` on the ids: `id`'s last UTF-16 code units are `sessionId`'s, with the same
    /// reservation as ``sameUnits(_:_:)`` against Swift's `hasSuffix`.
    private static func endsWithUnits(_ id: String, _ sessionId: String) -> Bool {
        let units = id.utf16
        let wanted = sessionId.utf16
        guard units.count >= wanted.count else { return false }
        return units.suffix(wanted.count).elementsEqual(wanted)
    }

    /// acpx's `retainMatch`: two matches say all there is to say of an id.
    private static func retainMatch(_ matches: inout [SessionRecord], _ record: SessionRecord) {
        if matches.count < 2 { matches.append(record) }
    }

    /// ``resolveRecord(_:)`` for a tool that answers an id no record has with `false` rather than
    /// a failure: nil then; an id that resolves to no one record still fails.
    func resolveRecordIfAny(_ sessionId: String) throws -> SessionRecord? {
        do {
            return try resolveRecord(sessionId)
        } catch DaemonError.sessionNotFound {
            return nil
        }
    }

    /// A record read again by its own id after this actor suspended — its file, and nothing else,
    /// as acpx reloads one (`readSessionRecord(acpxRecordId)`): a file gone or unreadable
    /// meanwhile is a miss, never another record whose id ends with this one, which the suffix
    /// resolution of ``resolveRecord(_:)`` would hand a close or a turn (Codex on #310).
    func reloadRecord(_ recordId: String) -> SessionRecord? {
        SessionStore.loadRecord(recordId)
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
            }
            // The files go once no agent of theirs is left to write them, as acpx's prune removes
            // them: the sessions directory read once.
            bytesFreed = SessionStore.deleteRecords(candidates.map(\.acpxRecordId), includeHistory: includeHistory)
        }
        return PruneResult(
            count: candidates.count, bytesFreed: bytesFreed, dryRun: dryRun,
            pruned: candidates.map(\.acpxRecordId))
    }
}
