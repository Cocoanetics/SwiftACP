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
    /// - Returns: the new session's acpx record id.
    @MCPTool(openWorldHint: true)
    func newSession(
        agentCommand: String, cwd: String, name: String? = nil,
        mcpServers: [McpServerConfig]? = nil
    ) async throws -> String {
        try await backend.newSession(
            agentCommand: agentCommand, cwd: cwd, name: name, mcpServers: mcpServers)
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
    @MCPTool(idempotentHint: true, openWorldHint: true)
    func setMode(sessionId: String, modeId: String) async throws -> Bool {
        try await backend.setMode(sessionId: sessionId, modeId: modeId)
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
    @MCPTool(idempotentHint: true, openWorldHint: true)
    func setConfigOption(sessionId: String, configId: String, value: String) async throws
        -> [JSONValue] {
        try await backend.setConfigOption(sessionId: sessionId, configId: configId, value: value)
    }

    /// Set a session's model on the live agent via the legacy `session/set_model`
    /// control (reconnecting if needed) and persist it as the current model —
    /// mirrors the CLI's `set model <value>` for legacy-control agents.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - modelId: the model id to switch to.
    @MCPTool(idempotentHint: true, openWorldHint: true)
    func setModel(sessionId: String, modelId: String) async throws -> Bool {
        try await backend.setModel(sessionId: sessionId, modelId: modelId)
    }

    /// Close a session: terminate its live agent (if held) and mark the record
    /// closed — mirrors the CLI's `sessions close`.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    /// - Returns: `false` if no such session exists.
    @MCPTool(idempotentHint: true)
    func closeSession(sessionId: String) async throws -> Bool {
        try await backend.closeSession(sessionId: sessionId)
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
    ///   - wait: when another turn is already running for this session, `true` (the
    ///     default) queues this one behind it; `false` rejects it immediately with a
    ///     "session busy" error instead of waiting.
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
    /// - Returns: the agent's aggregate response text for the turn. The turn's stop
    ///   reason is streamed separately as a final ``TurnEndedEvent`` log
    ///   notification (sent after the last `session/update`, before this returns).
    @MCPTool(openWorldHint: true)
    func runPrompt(
        sessionId: String, text: String, blocks: [PromptBlock]? = nil,
        wait: Bool = true, permissionMode: String? = nil, nonInteractivePermissions: String? = nil,
        streamWire: Bool? = nil
    ) async throws -> String {
        try await backend.runPrompt(
            sessionId: sessionId, text: text, blocks: blocks, wait: wait,
            permissionMode: permissionMode, nonInteractivePermissions: nonInteractivePermissions,
            streamWire: streamWire ?? false)
    }

    /// Cancel an in-flight prompt for a session.
    ///
    /// - Parameter sessionId: the ACP session id of the live session.
    /// - Returns: `false` if the session isn't currently live.
    @MCPTool(idempotentHint: true, openWorldHint: true)
    func cancelSession(sessionId: String) async throws -> Bool {
        try await backend.cancelSession(sessionId: sessionId)
    }
}
