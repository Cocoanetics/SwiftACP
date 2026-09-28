import Foundation
import JSONFoundation
import SwiftMCP

/// The acpx session daemon, exposed as an MCP server named `acpx`.
///
/// It holds live ACP agent sessions so prompts across CLI invocations (and remote
/// MCP clients) reuse one adapter process instead of respawning. It is served over
/// a Bonjour + local TCP transport (used by the `acpx` CLI) and, optionally, over
/// HTTP+SSE for outward MCP clients — see `acpxd`.
///
/// This is a thin `@MCPServer` *shell*: every tool delegates to an injected
/// ``ACPXBackend``, which `acpxd` implements with the real session/agent/store
/// logic. Keeping the shell free of macOS-only code lets the macro's generated
/// ``ACPXDaemon/Client`` compile for an iOS MCP client driving a remote daemon.
///
/// ## MCP tools
/// - ``newSession(agentCommand:cwd:name:mcpServers:)`` — create + persist a session
///   (optionally with its own MCP servers), return its id.
/// - ``runPrompt(sessionId:text:blocks:wait:)`` — run one prompt turn of text plus
///   optional content blocks (agent + cwd come from the session record),
///   streaming each ACP `session/update` back to the caller as an MCP log
///   notification, and returning the agent's aggregate response text. The turn's
///   stop reason arrives as a final ``TurnEndedEvent`` log notification.
/// - ``cancelSession(sessionId:)`` — cancel an in-flight prompt.
/// - ``sessionStatus(sessionId:)`` — whether the daemon holds a session live.
/// - ``listSessions(agentCommand:)`` / ``showSession(sessionId:)`` /
///   ``sessionHistory(sessionId:limit:)`` — read the persisted session store.
/// - ``setSessionMcpServers(sessionId:mcpServers:)`` / ``setMode(sessionId:modeId:)`` /
///   ``setConfigOption(sessionId:configId:value:)`` / ``closeSession(sessionId:)`` /
///   ``pruneSessions(agentCommand:olderThanDays:includeHistory:dryRun:)``
///   — mutate live sessions and the store.
@MCPServer(name: "acpx")
public actor ACPXDaemon {
    let backend: any ACPXBackend

    public init(backend: any ACPXBackend) {
        self.backend = backend
    }

    /// Run what a request asked for to its end, whatever becomes of the request: acpx's
    /// queue owner runs a prompt or control it has admitted though its client goes away
    /// (#181). SwiftMCP calls off a request's handler once its client's connection is
    /// gone, and none of that reaches `work`. `work` keeps the request's task-locals,
    /// the client's session among them, so the client hears of it for as long as it can.
    private func admitted<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await work() }.value
    }

    /// Create a new session for an agent, persist its `~/.acpx/sessions` record
    /// (the same record the CLI's `sessions new` writes), and return its id.
    ///
    /// The session id is then used with ``runPrompt(sessionId:text:blocks:wait:)``,
    /// which reconnects and holds the adapter live across prompts.
    ///
    /// - Parameters:
    ///   - agentCommand: the agent adapter to launch — a built-in name (`claude`,
    ///     `codex`), a config-defined agent alias, or a full command line. The
    ///     resolved launch command is stored on the session.
    ///   - cwd: the working directory the agent runs in (`~` is expanded).
    ///   - name: an optional session label (like `sessions new --name`); blank = none.
    ///   - mcpServers: MCP servers for this session only (the config-file
    ///     `mcpServers` shape). They *replace* the cwd's config-file servers — like
    ///     the CLI's `--mcp-config` — are persisted on the session, and are sent
    ///     again on every reconnect (`session/load` / `session/resume`), so they
    ///     survive daemon and adapter restarts. Omitted = use the config-file
    ///     servers; `[]` = none.
    ///   - agentArgv: the argv to launch the agent as, when the caller has resolved it —
    ///     recorded as the session's `agent_argv`. Omitted, the daemon splits the command.
    ///   - sessionOptions: the session's options (model, allowed tools, turns, system
    ///     prompt), recorded on it and sent as `_meta` with `session/new`; its model is put
    ///     on the session. Omitted, none.
    ///   - holdAgent: keep the agent that created the session, as the session's live agent,
    ///     for its first turn — as acpx's `createSessionWithClient` keeps its client for a
    ///     flow's first turn. Omitted, the agent is closed once the record is written.
    ///   - fs: acpx's `--no-fs`: `false` withholds the filesystem methods from the agent that
    ///     creates the session, as acpx's `sessions new --no-fs` withholds them from its client. The
    ///     record keeps none of it: a later agent is offered what its own turn asks for (#246).
    ///   - permissionMode: how the creating agent's permission requests and file writes are
    ///     answered, as `runPrompt`'s: `approve-all`, `approve-reads` or `deny-all` — a flow's
    ///     own mode, as acpx's runner makes its client with it. Omitted, `approve-all`.
    ///   - nonInteractivePermissions: `deny` or `fail`, as `runPrompt`'s. Omitted, `deny`.
    ///   - permissionPolicy: per-tool rules before `permissionMode`, as `runPrompt`'s.
    ///   - authPolicy: acpx's `--auth-policy` for the creating agent — `fail` refuses one that
    ///     advertises sign-in methods none of the credentials match. Omitted, as configured.
    ///   - callerConfig: the config the creating agent is started with — its credentials and,
    ///     without `mcpServers`, its MCP servers — in place of the config of `cwd`: a flow's,
    ///     read once as its run began, as acpx's runner gives every client of the run the
    ///     invocation's (``CallerConfig``). Omitted, the config of `cwd`.
    ///   - verbose: acpx's `--verbose`: what the agent writes to stderr is streamed to the
    ///     caller as ``AgentStderrEvent`` log notifications while the session is made, as
    ///     acpx's client shows it in the flow's process. A held agent's waits for its first
    ///     turn (`runPrompt`'s `verbose`). Omitted, it is not.
    ///   - creationToken: the caller's name for this creation, which `callOffCreation` can give
    ///     should its wait for the answer be cut short.
    ///   - environment: the environment the creating agent starts over, credentials laid over it
    ///     — the caller's own: a flow's, as acpx starts a flow's agents in the flow's process.
    ///     Omitted, the daemon's own.
    ///   - terminalOutputCeiling: the most output, in bytes, any terminal the creating agent opens
    ///     keeps — the caller's `ACPX_TERMINAL_MAX_OUTPUT_BYTES`, as `runPrompt`'s: `0` is no cap;
    ///     omitted, the daemon's own environment decides.
    /// - Returns: the new session's acpx record id.
    @MCPTool(openWorldHint: true)
    func newSession(
        agentCommand: String, cwd: String, name: String? = nil,
        mcpServers: [McpServerConfig]? = nil, agentArgv: [String]? = nil,
        sessionOptions: PromptSessionOptions? = nil, holdAgent: Bool? = nil, fs: Bool? = nil,
        permissionMode: String? = nil, nonInteractivePermissions: String? = nil,
        permissionPolicy: PermissionRules? = nil, authPolicy: String? = nil, callerConfig: CallerConfig? = nil,
        verbose: Bool? = nil, creationToken: String? = nil, environment: [String: String]? = nil,
        terminalOutputCeiling: Int? = nil
    ) async throws -> String {
        try await backend.newSession(
            agentCommand: agentCommand, agentArgv: agentArgv, cwd: cwd, name: name, mcpServers: mcpServers,
            sessionOptions: sessionOptions, creation: SessionCreationMode(
                holdAgent: holdAgent ?? false, fs: fs, permissionMode: permissionMode,
                nonInteractivePermissions: nonInteractivePermissions, permissionPolicy: permissionPolicy,
                authPolicy: authPolicy, callerConfig: callerConfig, verbose: verbose ?? false,
                creationToken: creationToken, environment: environment, terminalOutputCeiling: terminalOutputCeiling))
    }

    /// Call off the session `newSession` makes under `creationToken`, for a caller whose wait
    /// for its answer was cut short: one made is let go, and one not made yet is let go as it
    /// is made — as acpx's flow runner closes a client made after its attempt stopped.
    ///
    /// - Returns: whether a session made under the token was let go.
    @MCPTool
    func callOffCreation(creationToken: String) async throws -> Bool {
        try await backend.callOffCreation(creationToken: creationToken)
    }

    /// Replace a session's own MCP servers (see `newSession`'s `mcpServers`) and
    /// persist them. The change takes effect on the session's next reconnect; while
    /// the daemon still holds the session live with a *different* server set the
    /// call fails — mirroring npm acpx, where a live session cannot switch MCP
    /// config — unless `restart` says to reconnect it.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - mcpServers: the servers to attach from now on; `[]` detaches them all.
    ///   - restart: when the session is held live with a different set, drop that
    ///     connection instead of failing, so the next turn reconnects with the new
    ///     servers. Only the local adapter process goes away: the session itself is
    ///     restored with `session/load` / `session/resume`, so its history survives —
    ///     unlike npm acpx, whose per-session queue owner *is* the session and which
    ///     therefore has to be closed. Defaults to `false`, so a client never has a
    ///     warm adapter pulled out from under it by surprise.
    /// - Returns: `true` once persisted.
    @MCPTool(idempotentHint: true)
    func setSessionMcpServers(
        sessionId: String, mcpServers: [McpServerConfig], restart: Bool = false
    ) async throws -> Bool {
        try await backend.setSessionMcpServers(
            sessionId: sessionId, mcpServers: mcpServers, restart: restart)
    }

    /// List persisted sessions (newest-first), optionally filtered to one agent —
    /// mirrors the CLI's `sessions list`.
    ///
    /// - Parameter agentCommand: keep only sessions for this agent. A short name
    ///   (e.g. `claude`) matches sessions created with either that name or its
    ///   expanded launch command. Blank / omitted = every session.
    @MCPTool(readOnlyHint: true, idempotentHint: true)
    func listSessions(agentCommand: String? = nil) async -> [SessionSummary] {
        await backend.listSessions(agentCommand: agentCommand)
    }

    /// Show one persisted session's details — mirrors the CLI's `sessions show`.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    @MCPTool(readOnlyHint: true, idempotentHint: true)
    func showSession(sessionId: String) async throws -> SessionDetail {
        try await backend.showSession(sessionId: sessionId)
    }

    /// Return a session's conversation history (oldest-first) — mirrors the CLI's
    /// `sessions history`.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - limit: keep only the last N entries; 0 / omitted = all.
    @MCPTool(readOnlyHint: true, idempotentHint: true)
    func sessionHistory(sessionId: String, limit: Int? = nil) async throws -> [HistoryEntry] {
        try await backend.sessionHistory(sessionId: sessionId, limit: limit)
    }

    /// Set a session's mode on the live agent (reconnecting if needed) and persist
    /// it as the desired mode — mirrors the CLI's `set-mode`.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - modeId: the agent mode to switch to (e.g. `auto`, `read-only`).
    ///   - nonInteractivePermissions: `deny` (the default) or `fail` — what a request
    ///     needing confirmation does while the agent answers. A control approves reads
    ///     and asks about the rest, as acpx's direct controls do, and the daemon never
    ///     has anyone to ask.
    ///   - terminalOutputCeiling: the caller's cap on terminal output while the agent
    ///     answers — `ACPX_TERMINAL_MAX_OUTPUT_BYTES`, as for ``runPrompt(sessionId:text:blocks:wait:)``.
    ///     `0` is no cap; omitted, the daemon's own environment decides.
    ///   - timeoutMs: the caller's `--timeout`, in milliseconds, which the control fails
    ///     with `TIMEOUT` past, as acpx's does. Omitted or not positive, none.
    ///   - environment: the caller's environment. An agent the control starts for a session
    ///     no owner holds starts over it, as acpx's direct control starts its client in the
    ///     CLI's process; an owner's agents keep the one the owner started with (#222).
    ///     Omitted, the daemon's own.
    ///   - verbose: whether what an agent the control starts writes to stderr, and acpx's own
    ///     `[acpx]` lines, go to the caller as log notifications (``AgentStderrEvent``), as acpx's
    ///     direct control shows them in the CLI's process under `--verbose` — for a session no
    ///     owner holds (#221).
    ///   - fs: acpx's `--no-fs`: `false` withholds the filesystem methods from an agent the control
    ///     starts for a session no owner holds, as acpx's direct control builds its client with it;
    ///     an owner's agents keep what the prompt that started the owner asked for (#246).
    ///   - terminal: acpx's `--no-terminal`, the same way: `false` withholds the terminal.
    ///   - authPolicy: acpx's `--auth-policy`, the same way. Omitted, the session's config's.
    /// - Returns: whether the session had to be taken back first (``SessionControlResult``).
    @MCPTool(idempotentHint: true, openWorldHint: true)
    func setMode(
        sessionId: String, modeId: String, nonInteractivePermissions: String? = nil,
        terminalOutputCeiling: Int? = nil, timeoutMs: Int? = nil, environment: [String: String]? = nil,
        verbose: Bool? = nil, fs: Bool? = nil, terminal: Bool? = nil, authPolicy: String? = nil
    ) async throws -> SessionControlResult {
        try await admitted { [backend] in
            try await backend.setMode(
                sessionId: sessionId, modeId: modeId, nonInteractivePermissions: nonInteractivePermissions,
                terminalOutputCeiling: terminalOutputCeiling, timeoutMs: timeoutMs,
                environment: environment, verbose: verbose ?? false,
                client: ClientOptions(fs: fs, terminal: terminal, authPolicy: authPolicy))
        }
    }

    /// Set a session config option on the live agent (reconnecting if needed) and
    /// persist it as desired — mirrors the CLI's `set <key> <value>`.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - configId: the config option key the agent advertised.
    ///   - value: the value to set for that option.
    ///   - nonInteractivePermissions: as `setMode`'s: `deny` (the default) or `fail`.
    ///   - terminalOutputCeiling: as `setMode`'s: the caller's cap on terminal output, `0` for none.
    ///   - timeoutMs: as `setMode`'s: the caller's `--timeout`, in milliseconds.
    ///   - environment: as `setMode`'s: the caller's environment, for an agent the control starts.
    ///   - verbose: as `setMode`'s: whether that agent's stderr goes to the caller.
    ///   - fs: as `setMode`'s: `false` withholds the filesystem methods from that agent.
    ///   - terminal: as `setMode`'s: `false` withholds the terminal from that agent.
    ///   - authPolicy: as `setMode`'s: how that agent signs in.
    /// - Returns: the agent's advertised config options after the change (the data
    ///   the CLI echoes; may be empty if the agent reports none), and whether the
    ///   session had to be taken back first.
    @MCPTool(idempotentHint: true, openWorldHint: true)
    func setConfigOption(
        sessionId: String, configId: String, value: String, nonInteractivePermissions: String? = nil,
        terminalOutputCeiling: Int? = nil, timeoutMs: Int? = nil, environment: [String: String]? = nil,
        verbose: Bool? = nil, fs: Bool? = nil, terminal: Bool? = nil, authPolicy: String? = nil
    ) async throws -> SessionControlResult {
        try await admitted { [backend] in
            try await backend.setConfigOption(
                sessionId: sessionId, configId: configId, value: value,
                nonInteractivePermissions: nonInteractivePermissions, terminalOutputCeiling: terminalOutputCeiling,
                timeoutMs: timeoutMs, environment: environment, verbose: verbose ?? false,
                client: ClientOptions(fs: fs, terminal: terminal, authPolicy: authPolicy))
        }
    }

    /// Set a session's model on the live agent via the legacy `session/set_model`
    /// control (reconnecting if needed) and persist it as the current model —
    /// mirrors the CLI's `set model <value>` for legacy-control agents.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - modelId: the model id to switch to.
    ///   - nonInteractivePermissions: as `setMode`'s: `deny` (the default) or `fail`.
    ///   - terminalOutputCeiling: as `setMode`'s: the caller's cap on terminal output, `0` for none.
    ///   - timeoutMs: as `setMode`'s: the caller's `--timeout`, in milliseconds.
    ///   - environment: as `setMode`'s: the caller's environment, for an agent the control starts.
    ///   - verbose: as `setMode`'s: whether that agent's stderr goes to the caller.
    ///   - fs: as `setMode`'s: `false` withholds the filesystem methods from that agent.
    ///   - terminal: as `setMode`'s: `false` withholds the terminal from that agent.
    ///   - authPolicy: as `setMode`'s: how that agent signs in.
    /// - Returns: whether the session had to be taken back first (``SessionControlResult``).
    @MCPTool(idempotentHint: true, openWorldHint: true)
    func setModel(
        sessionId: String, modelId: String, nonInteractivePermissions: String? = nil,
        terminalOutputCeiling: Int? = nil, timeoutMs: Int? = nil, environment: [String: String]? = nil,
        verbose: Bool? = nil, fs: Bool? = nil, terminal: Bool? = nil, authPolicy: String? = nil
    ) async throws -> SessionControlResult {
        try await admitted { [backend] in
            try await backend.setModel(
                sessionId: sessionId, modelId: modelId, nonInteractivePermissions: nonInteractivePermissions,
                terminalOutputCeiling: terminalOutputCeiling, timeoutMs: timeoutMs,
                environment: environment, verbose: verbose ?? false,
                client: ClientOptions(fs: fs, terminal: terminal, authPolicy: authPolicy))
        }
    }

    /// Close a session: terminate its live agent (if held) and mark the record
    /// closed — mirrors the CLI's `sessions close`.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    /// - Returns: `false` if no such session exists.
    @MCPTool(idempotentHint: true)
    func closeSession(sessionId: String) async throws -> Bool {
        try await admitted { [backend] in try await backend.closeSession(sessionId: sessionId) }
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
    @MCPTool(destructiveHint: true, idempotentHint: true)
    func pruneSessions(
        agentCommand: String? = nil, olderThanDays: Int? = nil,
        includeHistory: Bool = false, dryRun: Bool = false
    ) async -> PruneResult {
        await backend.pruneSessions(
            agentCommand: agentCommand, olderThanDays: olderThanDays,
            includeHistory: includeHistory, dryRun: dryRun)
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
    ///   - text: the prompt text. May be empty when `blocks` carries the turn.
    ///   - blocks: ACP content blocks to send after the text — an image, a
    ///     `resource_link` handing over a file, or inline resource text. The turn is
    ///     refused up front if a block is malformed or the agent never advertised the
    ///     capability it needs. See ``PromptBlock`` for which blocks are worth sending.
    ///   - content: ACP content blocks to send after the text as written, checked by
    ///     acpx's rules instead of `blocks`' stricter ones — any `image/*` or `audio/*`
    ///     type, a `blob` resource — and refused, like acpx, by the first block that falls
    ///     short (`prompt[<i>] …`). What the acpx CLI sends for a structured prompt.
    ///   - wait: `true` (the default) runs the turn — behind any the session runs or has
    ///     waiting — and returns once it is over. `false` is acpx's `--no-wait`: the turn is
    ///     queued the same way, and the call returns (`""`) as soon as the session's line has
    ///     it; the turn runs on, its output going to no one, as acpx's owner runs a task it
    ///     does not wait for. A prompt refused before the line takes it fails the call either
    ///     way. A direct turn that may not wait is refused at once with "session busy" while
    ///     anything holds the session.
    ///   - permissionMode: how this turn's permission requests and file writes are
    ///     answered — `approve-all`, `approve-reads` or `deny-all`, as acpx's
    ///     `--approve-all` / `--approve-reads` / `--deny-all`. Applies to this turn
    ///     only; acpx sends it with every prompt. Omitted, the turn approves everything
    ///     as before.
    ///   - nonInteractivePermissions: `deny` or `fail` — what a write needing
    ///     confirmation does, since the daemon never has a terminal to ask on.
    ///     Defaults to `deny`.
    ///   - streamWire: also stream every ACP message of the turn as a
    ///     ``WireMessageEvent``, as acpx's `--format json` prints them. The messages of
    ///     connecting the agent for the turn are streamed either way.
    ///   - permissionPolicy: per-tool rules that approve, deny or escalate this turn's
    ///     permission requests ahead of `permissionMode` — acpx's
    ///     `--permission-policy`. See ``PermissionRules``.
    ///   - terminalOutputCeiling: the most output, in bytes, any terminal the agent
    ///     creates from this turn on keeps, whatever it asks for — the caller's
    ///     `ACPX_TERMINAL_MAX_OUTPUT_BYTES`, which acpx reads in the queue owner its CLI
    ///     starts. `0` is no cap; omitted, the daemon's own environment decides.
    ///   - model: acpx's `--model` for this turn: put on the session before the prompt,
    ///     through the control it advertises, and pinned as the session's model. The
    ///     turn fails before the prompt if the session cannot take it.
    ///   - sessionOptions: acpx's `--model`, `--allowed-tools`, `--max-turns` and
    ///     `--system-prompt` for this turn. See ``PromptSessionOptions``. Its model, when
    ///     it has one, is the turn's; `model` fills in when it has none.
    ///   - limits: acpx's `--timeout`, `--prompt-retries` and `--ttl` for this turn: how
    ///     long each of its steps may take, how often a prompt that failed the way a
    ///     passing fault does is sent again, and how long the session is kept once idle.
    ///     See ``PromptLimits``. Omitted, no limit, no retry, and five minutes.
    ///   - direct: run the turn as acpx's `sendSessionDirect` runs a flow's persistent
    ///     turn: the session is taken back as itself or not at all, the agent is let go
    ///     when the turn ends, and the journal has the turn's messages without turn records.
    ///     Omitted, as a queued prompt.
    ///   - fs: acpx's `--no-fs` for an agent the turn connects: `false` withholds the filesystem
    ///     methods, as acpx's flow runner gives it every client it makes. A queued turn's agents
    ///     are offered what the prompt that started the session's owner asked for, as acpx's owner
    ///     builds its client from the prompt that spawned it (#246). Omitted, they are offered.
    ///   - terminal: acpx's `--no-terminal` for an agent the turn connects, the same way: `false`
    ///     withholds the terminal. Omitted, it is offered.
    ///   - authPolicy: acpx's `--auth-policy` for an agent the turn connects, the same way.
    ///     Omitted, as configured.
    ///   - turnToken: the caller's name for the turn, which `cancelSession` can give: a
    ///     cancel that named it before it began ends it as it begins, nothing sent.
    ///   - callerConfig: the config an agent the turn connects is started with — its
    ///     credentials and, for a session without its own, its MCP servers — a flow's, as
    ///     `newSession`'s. Omitted, the config of the session's cwd.
    ///   - verbose: acpx's `--verbose`: what the agent writes to stderr is streamed to the
    ///     caller as ``AgentStderrEvent`` log notifications while the turn runs — first what
    ///     a held agent wrote since its session was made. Omitted, it is not.
    ///   - requestId: the caller's name for a queued turn, which its journal records are keyed by
    ///     (`turn_started`, `turn_result`, `last_request_id`), as acpx's owner keys them by the
    ///     request id its CLI sent — the id `--no-wait` prints. Omitted, one of the daemon's own.
    ///   - environment: the environment an agent the turn connects starts over — the caller's
    ///     own, as `newSession`'s. A queued turn's agents start over the environment of the
    ///     prompt that started the session's owner, as acpx's queue owner starts its agent in
    ///     the environment of the CLI that spawned it (#222). Omitted, the daemon's own.
    /// - Returns: the agent's aggregate response text for the turn. The turn's stop
    ///   reason is streamed separately as a final ``TurnEndedEvent`` log
    ///   notification (sent after the last `session/update`, before this returns).
    @MCPTool(openWorldHint: true)
    func runPrompt(
        sessionId: String, text: String, blocks: [PromptBlock]? = nil, content: [JSONValue]? = nil,
        wait: Bool = true, permissionMode: String? = nil, nonInteractivePermissions: String? = nil,
        streamWire: Bool? = nil, permissionPolicy: PermissionRules? = nil, terminalOutputCeiling: Int? = nil,
        model: String? = nil, sessionOptions: PromptSessionOptions? = nil, limits: PromptLimits? = nil,
        direct: Bool? = nil, fs: Bool? = nil, terminal: Bool? = nil, authPolicy: String? = nil,
        turnToken: String? = nil, callerConfig: CallerConfig? = nil, verbose: Bool? = nil,
        environment: [String: String]? = nil, requestId: String? = nil
    ) async throws -> String {
        let options = Self.turnOptions(sessionOptions, model: model)
        return try await admitted { [backend] in
            try await backend.runPrompt(
                sessionId: sessionId, text: text, blocks: blocks, content: content, wait: wait,
                permissionMode: permissionMode, nonInteractivePermissions: nonInteractivePermissions,
                mode: PromptTurnMode(
                    streamWire: streamWire ?? false, direct: direct ?? false, fs: fs, terminal: terminal,
                    authPolicy: authPolicy, turnToken: turnToken, callerConfig: callerConfig, verbose: verbose ?? false,
                    environment: environment, requestId: requestId),
                permissionPolicy: permissionPolicy, terminalOutputCeiling: terminalOutputCeiling,
                sessionOptions: options, limits: limits)
        }
    }

    /// A turn's session options with its `model`, which a CLI from before `sessionOptions`
    /// sends on its own.
    static func turnOptions(_ options: PromptSessionOptions?, model: String?) -> PromptSessionOptions? {
        guard let model, options?.model == nil else { return options }
        var withModel = options ?? PromptSessionOptions()
        withModel.model = model
        return withModel
    }

    /// Whether the daemon holds a session live — its agent connected and kept between
    /// prompts, as acpx's queue owner keeps one — and the agent's process id while it
    /// runs: what the CLI's prompt banner and `status` report. Connects nothing.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    @MCPTool(readOnlyHint: true, idempotentHint: true)
    func sessionStatus(sessionId: String) async -> LiveSessionStatus {
        await backend.sessionStatus(sessionId: sessionId)
    }

    /// Cancel an in-flight prompt for a session.
    ///
    /// - Parameters:
    ///   - sessionId: the ACP session id of the live session.
    ///   - turnToken: cancel only the turn `runPrompt` was given this token for — and, when it
    ///     has not begun yet, end it as it begins, nothing sent, as acpx's flow runner closes
    ///     the client a stopped direct turn would prompt on. Omitted, whatever turn runs.
    /// - Returns: whether a turn was cancelled — not if the session isn't currently live — and
    ///   the daemon's pid when the session's owner took the cancel (``SessionCancelResult``).
    @MCPTool(idempotentHint: true, openWorldHint: true)
    func cancelSession(sessionId: String, turnToken: String? = nil) async throws -> SessionCancelResult {
        try await admitted { [backend] in
            try await backend.cancelSessionReportingOwner(sessionId: sessionId, turnToken: turnToken)
        }
    }

    /// Let go of a session's live agent without closing the session: the daemon stops
    /// holding it and ends its agent, and the record stays as it is — what `sessions new`
    /// asks when the agent gave the new session the id of the one it replaces.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - turnToken: the caller's name for a turn (`runPrompt`'s): only the agent that turn
    ///     connects or runs on is put down, while the turn has the session — as acpx's flow
    ///     runner closes the client its stopped turn was handed. Omitted, the session's agent.
    /// - Returns: whether the daemon held an agent for it — or, given a turn, put one down.
    @MCPTool(idempotentHint: true)
    func releaseSession(sessionId: String, turnToken: String? = nil) async throws -> Bool {
        try await admitted { [backend] in try await backend.releaseSession(sessionId: sessionId, turnToken: turnToken) }
    }
}
