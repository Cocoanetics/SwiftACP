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

    /// Live sessions held open between prompts, keyed by acpx record id.
    var live: [String: Live] = [:]
    /// Agents being connected, until held, by record: what a close past its grace puts
    /// down (``ConnectingAgent``).
    var connecting: [String: ConnectingAgent] = [:]
    /// Set once the daemon lets its agents go for good (``releaseAll()``): from then on
    /// no agent is started or held.
    var stopping = false

    /// Serializes prompt turns per session so concurrent CLI/MCP callers can't drive
    /// one agent — or persist one record — at the same time (see ``SessionTurnQueue``).
    /// Internal (not private) so the prompt turns in `ACPXDaemonBackend+Prompt.swift`
    /// can take a session's slot.
    let turnQueue = SessionTurnQueue()
    /// The turn each session runs, by record: see ``TurnControl``.
    var turns: [String: TurnControl] = [:]
    /// The controls each prompt's turn takes while it runs, by record: see ``PromptControlTicket``.
    var tickets: [String: PromptControlTicket] = [:]
    /// The sessions held as acpx's queue owner holds one, by record: see ``SessionOwner``.
    var owners: [String: SessionOwner] = [:]
    /// For tests: run as a turn's prompt is about to be written, once a cancel can no
    /// longer keep it from going out.
    var promptGoingOut: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once a turn's prompt is answered, before the turn first looks at
    /// how many requests the agent has made.
    var beforeReplyDrain: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run each time a turn's updates have gone quiet past its answer, before
    /// it looks for requests of the agent's.
    var afterUpdateDrain: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once the pause before a retry has begun, which a cancel from then on
    /// cuts short.
    var retryPaused: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once a session's owner has stopped, its agent closed and its record
    /// written.
    var ownerStopped: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once connecting has moved the record to what it connected, before
    /// the agent is held.
    var reconnected: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once an owned control's deadline has passed, before what it connects
    /// or runs on is put down.
    var deadlinePassed: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once a control over past its deadline begins to wait for what that
    /// deadline puts down.
    var controlOverdue: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once a control sent during a prompt is taken on the prompt's ticket,
    /// before it waits for the prompt to go out.
    var controlTakenDuringPrompt: (@Sendable (_ recordId: String) async -> Void)?

    let log = Logger(label: "com.cocoanetics.acpx.acpxd.backend")

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
            // Its agent is gone: the record keeps no pid for it, as `closeSession` keeps none.
            record.pid = nil
        }
        var acpx = record.acpx ?? SessionAcpxState()
        acpx.mcpServers = mcpServers
        record.acpx = acpx
        record.lastUsedAt = nowISO()
        try SessionStore.writeRecord(record)
        return true
    }

    // MARK: - Mutation tools

    /// A call's cap on terminal output: the caller's — bytes, `0` for none — else the
    /// daemon's own `ACPX_TERMINAL_MAX_OUTPUT_BYTES`. A bad one is refused before the
    /// call waits for the session.
    static func terminalOutputCeiling(_ requested: Int?) throws -> Int? {
        guard let requested else { return try TerminalOutputLimit.ceiling() }
        return try TerminalOutputLimit.ceiling(bytes: requested)
    }

    /// Set a session's mode on the live agent (reconnecting if needed) and persist
    /// it as the desired mode — mirrors the CLI's `set-mode`.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - modeId: the agent mode to switch to (e.g. `auto`, `read-only`).
    ///   - nonInteractivePermissions: `deny` (the default) or `fail`: what a request
    ///     needing confirmation meanwhile does.
    ///   - terminalOutputCeiling: the caller's cap on terminal output, `0` for none;
    ///     omitted, the daemon's own.
    ///   - timeoutMs: the caller's `--timeout`, in milliseconds (see
    ///     ``withSessionTurn(_:replacing:nonInteractivePermissions:terminalOutputCeiling:timeoutMs:_:)``).
    func setMode(
        sessionId: String, modeId: String, nonInteractivePermissions: String? = nil,
        terminalOutputCeiling: Int? = nil, timeoutMs: Int? = nil
    ) async throws -> SessionControlResult {
        let step = ControlStep<Void, Void>(
            request: { entry, _, timeout in
                let session = entry.session
                try await withTimeout(milliseconds: timeout) {
                    try await SessionControlError.wrapping("session/set_mode", context: "for mode \"\(modeId)\"") {
                        try await session.setMode(modeId)
                    }
                }
            },
            apply: { _, record in
                // Only the mode to put back, as acpx's `setDesiredModeId`: the current mode
                // is what the agent's `current_mode_update` of a turn says.
                var acpx = record.acpx ?? SessionAcpxState()
                acpx.desiredModeId = modeId
                record.acpx = acpx
            })
        let (_, resumed) = try await runControl(
            sessionId, replacing: .mode, nonInteractivePermissions: nonInteractivePermissions,
            terminalOutputCeiling: terminalOutputCeiling, timeoutMs: timeoutMs, step)
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
    ///   - nonInteractivePermissions: `deny` (the default) or `fail`: what a request
    ///     needing confirmation meanwhile does.
    ///   - terminalOutputCeiling: the caller's cap on terminal output, `0` for none;
    ///     omitted, the daemon's own.
    ///   - timeoutMs: the caller's `--timeout`, in milliseconds (see
    ///     ``withSessionTurn(_:replacing:nonInteractivePermissions:terminalOutputCeiling:timeoutMs:_:)``).
    /// - Returns: the agent's advertised config options after the change (the data
    ///   the CLI echoes; may be empty if the agent reports none), and whether the
    ///   session had to be taken back first.
    func setConfigOption(
        sessionId: String, configId: String, value: String, nonInteractivePermissions: String? = nil,
        terminalOutputCeiling: Int? = nil, timeoutMs: Int? = nil
    ) async throws -> SessionControlResult {
        let step = ControlStep(
            request: { entry, record, timeout in
                // acpx's owner control: a value for the model's own option is a model id,
                // checked and resolved against the session's advertised models.
                let (connection, id) = (entry.agent.connection, entry.session.id)
                let models = ModelSupport.advertisedModelState(record.acpx ?? SessionAcpxState())
                let agentCommand = record.agentCommand
                return try await withTimeout(milliseconds: timeout) {
                    try await ModelApplication.setConfigOption(
                        connection: connection, sessionId: id, configId: configId, value: value, models: models,
                        agentCommand: agentCommand)
                }
            },
            apply: { (response: SetSessionConfigOptionResponse, record: inout SessionRecord) in
                var acpx = record.acpx ?? SessionAcpxState()
                ModelSupport.applyConfigOptionSelection(configId, value: value, response: response, to: &acpx)
                record.acpx = acpx
                return response.configOptions ?? []
            })
        let (options, resumed) = try await runControl(
            sessionId, replacing: .configOption(configId), nonInteractivePermissions: nonInteractivePermissions,
            terminalOutputCeiling: terminalOutputCeiling, timeoutMs: timeoutMs, step)
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
    ///   - nonInteractivePermissions: `deny` (the default) or `fail`: what a request
    ///     needing confirmation meanwhile does.
    ///   - terminalOutputCeiling: the caller's cap on terminal output, `0` for none;
    ///     omitted, the daemon's own.
    ///   - timeoutMs: the caller's `--timeout`, in milliseconds (see
    ///     ``withSessionTurn(_:replacing:nonInteractivePermissions:terminalOutputCeiling:timeoutMs:_:)``).
    func setModel(
        sessionId: String, modelId: String, nonInteractivePermissions: String? = nil,
        terminalOutputCeiling: Int? = nil, timeoutMs: Int? = nil
    ) async throws -> SessionControlResult {
        let step = ControlStep(
            request: { entry, record, timeout in
                let (connection, id) = (entry.agent.connection, entry.session.id)
                let models = ModelSupport.advertisedModelState(record.acpx ?? SessionAcpxState())
                let agentCommand = record.agentCommand
                return try await withTimeout(milliseconds: timeout) {
                    try await ModelApplication.setModel(
                        connection: connection, sessionId: id, modelId: modelId, models: models,
                        agentCommand: agentCommand)
                }
            },
            apply: { (response: SetSessionConfigOptionResponse?, record: inout SessionRecord) in
                var acpx = record.acpx ?? SessionAcpxState()
                ModelSupport.applyModelSelection(modelId, response: response, to: &acpx)
                record.acpx = acpx
            })
        let (_, resumed) = try await runControl(
            sessionId, replacing: .configOption("model"), nonInteractivePermissions: nonInteractivePermissions,
            terminalOutputCeiling: terminalOutputCeiling, timeoutMs: timeoutMs, step)
        return SessionControlResult(resumed: resumed)
    }

    /// Whether this daemon holds a session live, and its agent's process while it runs:
    /// the health of acpx's queue owner, which the prompt banner and `status` report. A
    /// session is held while its owner holds it (``SessionOwner``) — its agent can be gone
    /// meanwhile, closed after a prompt timed out or exited on its own, as acpx's owner
    /// outlives its client's agent — and otherwise while its agent runs. An entry whose
    /// agent has exited, or whose connection has closed, is only kept until the next turn
    /// replaces it.
    func sessionStatus(sessionId: String) async -> LiveSessionStatus {
        guard let record = findRecord(sessionId) else { return LiveSessionStatus(live: false) }
        let owned = owners[record.acpxRecordId] != nil
        guard let entry = live[record.acpxRecordId] else { return LiveSessionStatus(live: owned) }
        let lifecycle = entry.agent.lifecycle
        guard lifecycle?.running != false, await !entry.agent.connection.isClosed else {
            return LiveSessionStatus(live: owned)
        }
        return LiveSessionStatus(live: true, pid: lifecycle?.pid.map { Int($0) })
    }

    /// Drop a live session — by its acpx record id — and terminate its agent (so the
    /// next call relaunches).
    func evict(_ recordId: String) async {
        guard let entry = live.removeValue(forKey: recordId) else { return }
        await entry.agent.close()
    }

    /// Let every held agent go the way acpx's queue owner does when it stops
    /// (`writeQueueOwnerLifecycleSnapshot`): each agent is closed, and how it ended goes
    /// into its record, best effort — no pid, and the connection it was closed on unless
    /// it had ended before.
    func releaseAll() async {
        // Before anything is let go: a turn whose agent this closes must not start another.
        stopping = true
        for recordId in owners.keys { forgetOwner(recordId) }
        while let recordId = live.keys.first {
            guard let entry = live.removeValue(forKey: recordId) else { continue }
            await entry.agent.close()
            // A turn the close ends saves its record first.
            guard (try? await turnQueue.acquire(recordId, wait: true)) != nil else { continue }
            defer { Task { await turnQueue.release(recordId) } }
            guard var record = findRecord(recordId) else { continue }
            record.applyLifecycle(entry.agent.lifecycle)
            try? SessionStore.writeRecord(record)
        }
    }

    /// Whether `error` indicates the agent no longer has the session (ACP has no
    /// standard code, so match the text the agent puts in its error message/data).
    func isSessionGone(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        guard text.contains("session") else { return false }
        return ["not found", "unknown", "no such", "expired", "gone", "invalid"]
            .contains { text.contains($0) }
    }

}
