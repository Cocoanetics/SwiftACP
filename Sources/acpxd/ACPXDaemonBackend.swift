import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP

/// The macOS implementation of the acpx daemon's MCP tools — the ``ACPXBackend`` the
/// ``ACPXDaemon`` `@MCPServer` shell delegates to.
///
/// It holds live ACP agent sessions so prompts across CLI invocations (and remote
/// MCP clients) reuse one adapter process instead of respawning, owns the singleton
/// lock, and drives the persisted session store. `runPrompt` streams each ACP
/// `session/update` to the calling MCP client as a log notification — reaching the
/// serving session (`Session.current`) directly, since the backend runs inside the
/// tool-dispatch task. Run as a `Service` (see ``AcpxdCommand``) so it closes its
/// agents and releases the lock on shutdown.
actor ACPXDaemonBackend: ACPXBackend {
    /// A live agent handle + its session, keyed by ACP session id in ``live``.
    /// Internal (not private) so the ``Service`` conformance in `AcpxdCommand` can
    /// close them on shutdown.
    struct Live {
        let agent: ACPAgent
        let session: ACPSession
    }

    /// Live sessions held open between prompts, keyed by ACP session id.
    var live: [String: Live] = [:]

    /// Serializes prompt turns per session so concurrent CLI/MCP callers can't drive
    /// one agent — or persist one record — at the same time (see ``SessionTurnQueue``).
    private let turnQueue = SessionTurnQueue()

    /// When true, spawned agents inherit the daemon's stderr — surfacing agent
    /// diagnostics (e.g. rate-limit messages) that otherwise stay hidden.
    private let inheritAgentStderr: Bool

    /// The singleton lock the daemon holds for its lifetime and releases on a graceful
    /// shutdown (nil in tests that don't exercise the lifecycle). Released by the
    /// ``Service`` conformance in `AcpxdCommand`.
    let lock: DaemonLock?

    init(inheritAgentStderr: Bool = false, lock: DaemonLock? = nil) {
        self.inheritAgentStderr = inheritAgentStderr
        self.lock = lock
    }

    /// Create a new session for an agent, persist its `~/.acpx/sessions` record
    /// (the same record the CLI's `sessions new` writes), and return its id.
    ///
    /// The session id is then used with ``runPrompt(sessionId:text:)``, which
    /// reconnects and holds the adapter live across prompts.
    ///
    /// - Parameters:
    ///   - agentCommand: the agent adapter to launch — a built-in name (`claude`,
    ///     `codex`), a config-defined agent alias, or a full command line. The
    ///     resolved launch command is stored on the session.
    ///   - cwd: the working directory the agent runs in (`~` is expanded).
    ///   - name: an optional session label (like `sessions new --name`); blank = none.
    /// - Returns: the new session's acpx record id.
    func newSession(agentCommand: String, cwd rawCwd: String, name: String? = nil) async throws
        -> String {
        let cwd = try resolveCwd(rawCwd)
        let config = try ConfigLoader.load(cwd: cwd)
        let record = try await SessionEngine.createSession(
            agentCommand: launchCommand(for: agentCommand, config: config), cwd: cwd,
            name: nonBlank(name), permission: .approveAll, authCredentials: config.auth,
            authPolicy: config.authPolicy, inheritStderr: inheritAgentStderr)
        return record.acpxRecordId
    }

    /// Resolve an agent name to its launch command line, the way the CLI does — a
    /// built-in name or a config-defined alias (`config.agents`) maps to its full
    /// command; a full command line passes through unchanged. So an MCP client can
    /// say `agentCommand: "codex-alice"` and get the same wrapper the CLI uses.
    private func launchCommand(for agentCommand: String, config: ResolvedAcpxConfig) -> String {
        AgentRegistry.command(for: agentCommand, overrides: config.agents) ?? agentCommand
    }

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
    private func findRecord(_ id: String) -> SessionRecord? {
        if let record = SessionStore.loadRecord(id) { return record }
        return SessionStore.listSessions().first {
            $0.acpSessionId == id || $0.acpxRecordId == id
        }
    }

    /// Trim a caller-supplied string, returning nil when it's blank — so an empty
    /// MCP text field counts as "not provided" rather than a real (empty) value.
    private func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Persisted sessions matching an optional agent filter. A short name and its
    /// expanded registry command compare equal, so `claude` matches sessions
    /// created with either form. Blank / omitted returns every session.
    private func sessions(matchingAgent rawFilter: String?) -> [SessionRecord] {
        let all = SessionStore.listSessions()
        guard let filter = nonBlank(rawFilter) else { return all }
        let target = canonicalAgent(filter)
        return all.filter { canonicalAgent($0.agentCommand) == target }
    }

    /// Resolve a short agent name (e.g. `claude`) to its registry launch command;
    /// pass through anything that's already a full or custom command.
    private func canonicalAgent(_ value: String) -> String {
        AgentRegistry.command(for: value) ?? value
    }

    // MARK: - Mutation tools

    /// Run `body` holding the session's single turn slot, with a freshly-reloaded
    /// record, then stamp `last_used_at` and persist it. Serializes the control op
    /// against prompts and other control ops; reloading *after* acquiring means it
    /// builds on (and persists on top of) whatever turn it queued behind, rather than
    /// clobbering it.
    private func withSessionTurn<T: Sendable>(
        _ sessionId: String, _ body: (Live, inout SessionRecord) async throws -> T
    ) async throws -> T {
        guard let initial = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let acpSessionId = initial.acpSessionId
        try await turnQueue.acquire(acpSessionId, wait: true)
        defer { Task { await turnQueue.release(acpSessionId) } }
        guard var record = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let entry = try await ensure(
            sessionId: record.acpSessionId, agentCommand: record.agentCommand, cwd: record.cwd)
        let result = try await body(entry, &record)
        record.lastUsedAt = nowISO()
        try? SessionStore.writeRecord(record)
        return result
    }

    /// Set a session's mode on the live agent (reconnecting if needed) and persist
    /// it as the desired mode — mirrors the CLI's `set-mode`.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - modeId: the agent mode to switch to (e.g. `auto`, `read-only`).
    func setMode(sessionId: String, modeId: String) async throws -> Bool {
        try await withSessionTurn(sessionId) { entry, record in
            try await entry.session.setMode(modeId)
            var acpx = record.acpx ?? SessionAcpxState()
            acpx.desiredModeId = modeId
            acpx.currentModeId = modeId
            record.acpx = acpx
        }
        return true
    }

    /// Set a session config option on the live agent (reconnecting if needed) and
    /// persist it as desired — mirrors the CLI's `set <key> <value>`.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - configId: the config option key the agent advertised.
    ///   - value: the value to set for that option.
    /// - Returns: the agent's advertised config options after the change (the data
    ///   the CLI echoes; may be empty if the agent reports none).
    func setConfigOption(sessionId: String, configId: String, value: String) async throws
        -> [JSONValue] {
        try await withSessionTurn(sessionId) { entry, record in
            let response = try await entry.agent.connection.setConfigOption(
                SetSessionConfigOptionRequest(
                    sessionId: entry.session.id, configId: configId, value: value))
            var acpx = record.acpx ?? SessionAcpxState()
            var desired = acpx.desiredConfigOptions ?? [:]
            desired[configId] = value
            acpx.desiredConfigOptions = desired
            record.acpx = acpx
            return response.configOptions ?? []
        }
    }

    /// Set a session's model on the live agent via the legacy `session/set_model`
    /// control (reconnecting if needed) and persist it as the current model —
    /// mirrors the CLI's `set model <value>` for legacy-control agents.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - modelId: the model id to switch to.
    func setModel(sessionId: String, modelId: String) async throws -> Bool {
        try await withSessionTurn(sessionId) { entry, record in
            try await entry.agent.connection.setModel(
                SetSessionModelRequest(sessionId: entry.session.id, modelId: modelId))
            var acpx = record.acpx ?? SessionAcpxState()
            acpx.currentModelId = modelId
            record.acpx = acpx
        }
        return true
    }

    /// Close a session: terminate its live agent (if held) and mark the record
    /// closed — mirrors the CLI's `sessions close`.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    /// - Returns: `false` if no such session exists.
    func closeSession(sessionId: String) async throws -> Bool {
        guard var record = findRecord(sessionId) else { return false }
        await evict(record.acpSessionId)
        record.pid = nil
        record.closed = true
        record.closedAt = nowISO()
        try SessionStore.writeRecord(record)
        return true
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
                await evict(record.acpSessionId)
                bytesFreed += SessionStore.deleteRecord(
                    record.acpxRecordId, includeHistory: includeHistory)
            }
        }
        return PruneResult(
            count: candidates.count, bytesFreed: bytesFreed, dryRun: dryRun,
            pruned: candidates.map(\.acpxRecordId))
    }

    /// Run a prompt against an existing session, streaming each update as a log
    /// notification and returning the agent's aggregate response text.
    ///
    /// The agent command and working directory are read from the session's
    /// persisted record (created by `newSession`) — there's no need to repeat them,
    /// just as the acpx CLI takes cwd from the process, not from each prompt.
    ///
    /// - Parameters:
    ///   - sessionId: an existing session id (acpx record id or ACP session id).
    ///     Reconnects to it, recreating the underlying session only if its rollout
    ///     is gone. Must not be empty.
    ///   - text: the prompt text.
    ///   - wait: when another turn is already running for this session, `true` (the
    ///     default) queues this one behind it; `false` rejects it immediately with a
    ///     "session busy" error instead of waiting.
    /// - Returns: the agent's aggregate response text for the turn. The turn's stop
    ///   reason is streamed separately as a final ``TurnEndedEvent`` log
    ///   notification (sent after the last `session/update`, before this returns).
    func runPrompt(sessionId rawSessionId: String, text: String, wait: Bool = true) async throws
        -> String {
        let sessionId = rawSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { throw DaemonError.emptySessionId }
        guard let initial = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let acpSessionId = initial.acpSessionId

        // One turn per session at a time: queue behind any in-flight turn (or, when
        // wait == false, reject), so concurrent CLI/MCP callers never drive one
        // agent — or persist one record — concurrently. Keyed by ACP session id.
        try await turnQueue.acquire(acpSessionId, wait: wait)
        defer { Task { await turnQueue.release(acpSessionId) } }

        // Reload the record *after* acquiring the slot: a turn we queued behind has
        // just persisted new history, and the persister must build on that, not on a
        // stale pre-wait snapshot (whose final flush would otherwise clobber it).
        guard let record = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let agentCommand = record.agentCommand
        let cwd = record.cwd
        // Record the user's prompt once, up front; the persister checkpoints the
        // turn to disk on a debounce as updates stream in (acpx's live checkpoint),
        // draining the wire buffer into the event log on each save. A session-gone
        // retry reuses both, so the prompt isn't double-recorded.
        let eventBuffer = WireBuffer()
        let persister = TurnPersister(record: record, eventBuffer: eventBuffer)
        await persister.recordPrompt(text)
        do {
            return try await attemptPrompt(
                sessionId: acpSessionId, agentCommand: agentCommand, cwd: cwd, text: text,
                persister: persister, eventBuffer: eventBuffer)
        } catch {
            // A held session can disappear (the agent dropped it — e.g. after an
            // earlier failure). Evict the stale entry and try once more from a fresh
            // launch. Only retry for session-gone errors, never transient ones like
            // rate limits.
            guard isSessionGone(error) else { throw error }
            await evict(acpSessionId)
            return try await attemptPrompt(
                sessionId: acpSessionId, agentCommand: agentCommand, cwd: cwd, text: text,
                persister: persister, eventBuffer: eventBuffer)
        }
    }

    private func attemptPrompt(
        sessionId: String, agentCommand: String, cwd: String, text: String, persister: TurnPersister,
        eventBuffer: WireBuffer
    ) async throws -> String {
        let entry = try await ensure(sessionId: sessionId, agentCommand: agentCommand, cwd: cwd)
        let connection = entry.agent.connection
        let boundSessionId = entry.session.id
        // The calling client's MCP session — stream updates to it as log notifications.
        let clientSession = Session.current

        // Tee every JSON-RPC line on the wire into the buffer; the persister drains
        // it into the event log on each checkpoint. Cleared when the turn ends.
        await connection.setWireObserver { line in eventBuffer.append(line) }

        // Subscribe before prompting so no update is missed, then drain the
        // subscription deterministically: ending it (after `prompt` returns)
        // finishes the stream, so the consumer task completes having sent every
        // update — in order — and built the agent's message content for the turn.
        let (subscriptionId, stream) = await connection.makeSubscription()
        let consumer = Task { () -> String in
            // Accumulate the full streamed text for the MCP result, and fold each
            // update into the persister (which debounce-saves the record as it goes).
            var fullText = ""
            for await note in stream where note.sessionId == boundSessionId {
                if case .agentMessageChunk(let block) = note.update, let chunk = block.text {
                    fullText += chunk
                }
                await persister.apply(note.update)
                let payload = SessionNotification(sessionId: boundSessionId, update: note.update)
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: sessionId, data: toJSONValue(payload)))
            }
            return fullText
        }
        do {
            let response = try await entry.session.prompt(text)
            await connection.endSubscription(subscriptionId)
            await connection.setWireObserver(nil)
            let fullText = await consumer.value
            // Capture the token breakdown the agent reports on the response (Claude
            // Code does; acpx misses this — it only reads usage_update._meta.usage).
            if let usage = response.usage { await persister.applyResponseUsage(usage) }
            // Final checkpoint: stamp timestamps and flush the completed turn —
            // including any wire lines still buffered for the event log.
            await persister.finish()
            // Demote the stop reason to a streamed event: emit it last, after every
            // update, so a client reconstructing the turn sees it in order.
            await clientSession?.sendLogNotification(
                LogMessage(
                    level: .info, logger: sessionId,
                    data: toJSONValue(TurnEndedEvent(stopReason: response.stopReason.rawValue))))
            return fullText
        } catch {
            await connection.endSubscription(subscriptionId)
            await connection.setWireObserver(nil)
            consumer.cancel()
            throw error
        }
    }

    /// Drop a live session and terminate its agent (so the next call relaunches).
    func evict(_ sessionId: String) async {
        guard let entry = live.removeValue(forKey: sessionId) else { return }
        await entry.agent.close()
    }

    /// Whether `error` indicates the agent no longer has the session (ACP has no
    /// standard code, so match the text the agent puts in its error message/data).
    private func isSessionGone(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        guard text.contains("session") else { return false }
        return ["not found", "unknown", "no such", "expired", "gone", "invalid"]
            .contains { text.contains($0) }
    }

    /// Cancel an in-flight prompt for a session.
    ///
    /// - Parameter sessionId: the ACP session id of the live session.
    /// - Returns: `false` if the session isn't currently live.
    func cancelSession(sessionId: String) async throws -> Bool {
        guard let entry = live[sessionId] else { return false }
        try await entry.session.cancel()
        return true
    }

    /// Return the live entry for `sessionId`, launching/reconnecting if needed.
    private func ensure(sessionId: String, agentCommand: String, cwd rawCwd: String) async throws
        -> Live {
        if let existing = live[sessionId] { return existing }
        let cwd = try resolveCwd(rawCwd)
        // Resolve config for this cwd so the agent gets the same injected `auth`
        // credentials / auth policy (and config-alias resolution) the CLI applies.
        let config = try ConfigLoader.load(cwd: cwd)
        let handle = try await ACPAgent.launch(
            agent: launchCommand(for: agentCommand, config: config), cwd: cwd, permission: .approveAll,
            authCredentials: config.auth, authPolicy: config.authPolicy,
            inheritStderr: inheritAgentStderr)
        let session: ACPSession
        do {
            session = try await handle.reconnectSession(id: sessionId, cwd: cwd)
        } catch {
            let response = try await handle.connection.newSession(
                NewSessionRequest(cwd: cwd, mcpServers: []))
            session = ACPSession(id: response.sessionId, agent: handle, modes: response.modes)
        }
        let entry = Live(agent: handle, session: session)
        live[sessionId] = entry
        return entry
    }

    /// Expand and validate a caller-supplied working directory. MCP clients have no
    /// shell, so expand `~` ourselves (the CLI relies on the shell) and require the
    /// directory to exist — otherwise the agent fails with a cryptic internal error.
    private func resolveCwd(_ rawCwd: String) throws -> String {
        let cwd = (rawCwd as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw DaemonError.invalidCwd(rawCwd)
        }
        return cwd
    }
}
