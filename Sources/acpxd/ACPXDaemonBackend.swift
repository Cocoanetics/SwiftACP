import ACPXCore
import Foundation
import JSONFoundation
import Logging
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
        /// The session's *own* MCP servers as sent on the wire when this connection
        /// was made, or `nil` when the session uses the cwd's config-file servers.
        /// Normalized (not the raw config shape) so entries that differ only in
        /// omitted-vs-explicit defaults — `{name, command}` and
        /// `{type: "stdio", name, command, args: [], env: []}` — compare equal,
        /// the way npm acpx fingerprints the *parsed* server list. A record that
        /// later asks for a different set can't be served by this connection; a
        /// config-file-backed session (`nil`) never conflicts, matching npm, where
        /// only an explicit `--mcp-config` is fingerprinted — see ``ensure``.
        let sessionSpecs: [MCPServerSpec]?
    }

    /// Live sessions held open between prompts, keyed by ACP session id.
    var live: [String: Live] = [:]

    /// Serializes prompt turns per session so concurrent CLI/MCP callers can't drive
    /// one agent — or persist one record — at the same time (see ``SessionTurnQueue``).
    /// Internal (not private) so the prompt turns in `ACPXDaemonBackend+Prompt.swift`
    /// can take a session's slot.
    let turnQueue = SessionTurnQueue()

    private let log = Logger(label: "com.cocoanetics.acpx.acpxd.backend")

    /// When true, spawned agents inherit the daemon's stderr — surfacing agent
    /// diagnostics (e.g. rate-limit messages) that otherwise stay hidden.
    let inheritAgentStderr: Bool

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
    ///   - mcpServers: the session's own MCP servers, replacing the cwd's config-file
    ///     ones (like `--mcp-config`); persisted on the record and replayed on every
    ///     reconnect. `nil` = config-file servers; `[]` = none.
    /// - Returns: the new session's acpx record id.
    func newSession(
        agentCommand: String, cwd rawCwd: String, name: String? = nil,
        mcpServers: [McpServerConfig]? = nil
    ) async throws -> String {
        let cwd = try resolveCwd(rawCwd)
        let config = try ConfigLoader.load(cwd: cwd, ownMcpServers: mcpServers != nil)
        // Only normalize the config-file servers when they're the ones being sent:
        // a caller supplying its own set must not be refused over an unrelated bad
        // entry in the cwd's config.
        let configServers = mcpServers == nil ? try config.mcpServerSpecs() : []
        let launch = config.agentLaunch(for: agentCommand)
        let record = try await SessionEngine.createSession(
            agentCommand: launch.command, agentArgv: launch.argv, cwd: cwd,
            name: nonBlank(name), permission: .approveAll, authCredentials: config.auth,
            authPolicy: config.authPolicy, mcpServers: configServers,
            sessionMcpServers: mcpServers, inheritStderr: inheritAgentStderr)
        return record.acpxRecordId
    }

    /// Replace a session's own MCP servers and persist them (see `newSession`'s
    /// `mcpServers`); the next reconnect sends the new set. Refused while the daemon
    /// holds the session live with a different set — npm acpx likewise rejects
    /// switching a live session's MCP config ("close the session before retrying") —
    /// unless `restart` is set, which drops that connection so the next turn
    /// reconnects with the new servers, keeping the session (and its history) alive.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - mcpServers: the servers to attach from now on; `[]` detaches them all.
    ///   - restart: reconnect a live session instead of refusing the switch.
    /// - Returns: `true` once persisted.
    func setSessionMcpServers(
        sessionId: String, mcpServers: [McpServerConfig], restart: Bool = false
    ) async throws -> Bool {
        // Reject malformed entries up front, before touching the record.
        let specs = try mcpServers.map { try $0.protocolSpec() }
        guard let initial = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let recordId = initial.acpxRecordId
        // Take the session's turn slot so the check against the live connection
        // can't race a turn that is about to (re)connect it.
        try await turnQueue.acquire(recordId, wait: true)
        defer { Task { await turnQueue.release(recordId) } }
        // Re-read inside the slot: `evict` below (and any turn we queued behind) can
        // suspend us, so the write must build on the current record — found by its
        // record id, as that turn may have moved it to a new ACP session.
        guard var record = findRecord(recordId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        // Compare what would go on the wire, so re-sending the same servers written
        // differently (omitted vs explicit `args`/`env`/`type`) is the no-op it looks
        // like, rather than a conflict.
        if let entry = live[recordId], entry.sessionSpecs != specs {
            guard restart else { throw DaemonError.mcpConfigConflict(sessionId) }
            // Safe here: this call holds the session's turn slot, so no turn is in
            // flight. Only the adapter process goes; the record — and the agent's
            // rollout behind it — stay, so the next turn reconnects with the new set.
            await evict(recordId)
        }
        var acpx = record.acpx ?? SessionAcpxState()
        acpx.mcpServers = mcpServers
        record.acpx = acpx
        record.lastUsedAt = nowISO()
        try SessionStore.writeRecord(record)
        return true
    }

    // MARK: - Mutation tools

    /// Run `body` holding the session's single turn slot, with a freshly-reloaded
    /// record, then stamp `last_used_at` and persist it. Serializes the control op
    /// against prompts and other control ops; reloading *after* acquiring means it
    /// builds on (and persists on top of) whatever turn it queued behind, rather than
    /// clobbering it. Also says whether connecting had to take the session back
    /// (acpx's `resumed`).
    private func withSessionTurn<T: Sendable>(
        _ sessionId: String, _ body: (Live, inout SessionRecord) async throws -> T
    ) async throws -> (value: T, resumed: Bool) {
        guard let initial = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let recordId = initial.acpxRecordId
        try await turnQueue.acquire(recordId, wait: true)
        // `defer` can't await; the hop to the queue actor is safe because release
        // hands the slot to the next FIFO waiter regardless of when it lands.
        defer { Task { await turnQueue.release(recordId) } }
        guard let current = findRecord(recordId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let (entry, resumed) = try await connect(
            recordId: recordId, agentCommand: current.agentCommand, cwd: current.cwd,
            mcpServers: current.acpx?.mcpServers, control: true)
        // Read after connecting: a reconnect may have moved the record to a new session.
        var record = findRecord(recordId) ?? current
        let result = try await body(entry, &record)
        record.lastUsedAt = nowISO()
        do {
            // The control op already took effect on the live agent, so don't fail
            // the call over a bookkeeping write — but don't hide it either.
            try SessionStore.writeRecord(record)
        } catch {
            log.warning("session record write failed after control op: \(error)")
        }
        return (result, resumed)
    }

    /// Set a session's mode on the live agent (reconnecting if needed) and persist
    /// it as the desired mode — mirrors the CLI's `set-mode`.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - modeId: the agent mode to switch to (e.g. `auto`, `read-only`).
    func setMode(sessionId: String, modeId: String) async throws -> SessionControlResult {
        let (_, resumed) = try await withSessionTurn(sessionId) { entry, record in
            try await entry.session.setMode(modeId)
            var acpx = record.acpx ?? SessionAcpxState()
            acpx.desiredModeId = modeId
            acpx.currentModeId = modeId
            record.acpx = acpx
        }
        return SessionControlResult(resumed: resumed)
    }

    /// Set a session config option on the live agent (reconnecting if needed) and
    /// record it as acpx's `applyConfigOptionSelection` does — mirrors the CLI's
    /// `set <key> <value>`. The model's own option pins the model, so a reconnect puts
    /// back this one rather than what the session was created with.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - configId: the config option key the agent advertised.
    ///   - value: the value to set for that option.
    /// - Returns: the agent's advertised config options after the change (the data
    ///   the CLI echoes; may be empty if the agent reports none), and whether the
    ///   session had to be taken back first.
    func setConfigOption(sessionId: String, configId: String, value: String) async throws
        -> SessionControlResult {
        let (options, resumed) = try await withSessionTurn(sessionId) { entry, record in
            var acpx = record.acpx ?? SessionAcpxState()
            // acpx's owner control: a value for the model's own option is a model id,
            // checked and resolved against the session's advertised models.
            let response = try await ModelApplication.setConfigOption(
                connection: entry.agent.connection, sessionId: entry.session.id, configId: configId,
                value: value, models: ModelSupport.advertisedModelState(acpx), agentCommand: record.agentCommand)
            ModelSupport.applyConfigOptionSelection(configId, value: value, response: response, to: &acpx)
            record.acpx = acpx
            return response.configOptions ?? []
        }
        return SessionControlResult(resumed: resumed, configOptions: options)
    }

    /// Set a session's model on the live agent (reconnecting if needed) through the
    /// control the session advertises, as acpx's `setSessionModel` does — refused when
    /// it advertises none — and record it as `applyModelSelection` does: pinned and
    /// current. Mirrors the CLI's `set model <value>` for legacy-control agents.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - modelId: the model id to switch to.
    func setModel(sessionId: String, modelId: String) async throws -> SessionControlResult {
        let (_, resumed) = try await withSessionTurn(sessionId) { entry, record in
            var acpx = record.acpx ?? SessionAcpxState()
            let response = try await ModelApplication.setModel(
                connection: entry.agent.connection, sessionId: entry.session.id, modelId: modelId,
                models: ModelSupport.advertisedModelState(acpx), agentCommand: record.agentCommand)
            ModelSupport.applyModelSelection(modelId, response: response, to: &acpx)
            record.acpx = acpx
        }
        return SessionControlResult(resumed: resumed)
    }

    /// Close a session: terminate its live agent (if held) and mark the record
    /// closed — mirrors the CLI's `sessions close`.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    /// - Returns: `false` if no such session exists.
    func closeSession(sessionId: String) async throws -> Bool {
        guard let initial = findRecord(sessionId) else { return false }
        await evict(initial.acpxRecordId)
        // Re-read after the await: closing the agent suspends this actor, so another
        // tool (e.g. `setSessionMcpServers`, which the conflict message sends callers
        // here to unblock) may have persisted changes meanwhile. Writing the
        // pre-suspension snapshot would silently revert them.
        var record = findRecord(initial.acpxRecordId) ?? initial
        record.pid = nil
        record.closed = true
        record.closedAt = nowISO()
        try SessionStore.writeRecord(record)
        return true
    }

    /// Drop a live session — by its acpx record id — and terminate its agent (so the
    /// next call relaunches).
    func evict(_ recordId: String) async {
        guard let entry = live.removeValue(forKey: recordId) else { return }
        await entry.agent.close()
    }

    /// Whether `error` indicates the agent no longer has the session (ACP has no
    /// standard code, so match the text the agent puts in its error message/data).
    func isSessionGone(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        guard text.contains("session") else { return false }
        return ["not found", "unknown", "no such", "expired", "gone", "invalid"]
            .contains { text.contains($0) }
    }

    /// Cancel an in-flight prompt for a session.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    /// - Returns: `false` if the session isn't currently live.
    func cancelSession(sessionId: String) async throws -> Bool {
        // An agent that exited has no turn to cancel.
        guard let record = findRecord(sessionId), let entry = live[record.acpxRecordId],
            await !entry.agent.connection.isClosed
        else { return false }
        try await entry.session.cancel()
        return true
    }
}
