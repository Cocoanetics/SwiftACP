import Foundation
import JSONFoundation

// The acpx daemon's MCP tool DTOs — the structured wire types the `acpx` MCP server
// accepts, returns and streams. They live in this shared, iOS-capable library (rather
// than the macOS-only `ACPXCore`) so the generated `ACPXDaemon.Client` and an iOS MCP
// client can encode/decode them. `ACPXCore` adds the `init(record:)` convenience
// initializers that map a persisted `SessionRecord` into these.

/// An MCP server entry in acpx's *config* shape — the flat stdio / http / sse union
/// that `mcpServers` takes in `~/.acpx/config.json`, `.acpxrc.json` and `--mcp-config`
/// files (npm acpx's `McpServerConfig`), and that the daemon's `newSession` /
/// `setSessionMcpServers` tools accept per session.
///
/// It is deliberately a flat struct rather than the ACP wire enum ``MCPServerSpec``:
/// an MCP tool parameter needs a JSON schema (`@Schema`), which only structs get, and
/// callers should be able to omit `args` / `env` the way a config file can. `ACPXCore`
/// normalizes it to the wire shape (`McpServerConfig.protocolSpec()`).
@Schema
public struct McpServerConfig: Codable, Hashable, Sendable {
    /// The transport: `stdio` (the default when omitted), `http`, or `sse`.
    public var type: String?
    /// The server's name, as the agent lists it.
    public var name: String
    /// stdio: the executable the agent spawns.
    public var command: String?
    /// stdio: arguments for `command`.
    public var args: [String]?
    /// stdio: environment variables for the spawned server.
    public var env: [EnvEntry]?
    /// http / sse: the server URL.
    public var url: String?
    /// http / sse: HTTP headers to send.
    public var headers: [EnvEntry]?
    /// Optional `_meta` object, forwarded to the agent verbatim.
    public var meta: [String: JSONValue]?

    /// A name/value pair, used for both `env` (stdio) and `headers` (http/sse).
    @Schema
    public struct EnvEntry: Codable, Hashable, Sendable {
        /// The variable / header name.
        public var name: String
        /// Its value.
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, name, command, args, env, url, headers
        case meta = "_meta"
    }

    public init(
        type: String? = nil, name: String, command: String? = nil, args: [String]? = nil,
        env: [EnvEntry]? = nil, url: String? = nil, headers: [EnvEntry]? = nil,
        meta: [String: JSONValue]? = nil
    ) {
        self.type = type
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.meta = meta
    }
}

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
    /// The session's own MCP servers (set via `newSession` / `setSessionMcpServers`
    /// or `--mcp-config`), replayed on every reconnect; `nil` = the session uses the
    /// cwd's config-file servers.
    public var mcpServers: [McpServerConfig]?

    public init(
        id: String, sessionId: String, agentSessionId: String?, agentCommand: String,
        cwd: String, name: String?, createdAt: String, lastUsedAt: String,
        lastPromptAt: String?, closed: Bool, closedAt: String?, pid: Int?,
        agentStartedAt: String?, lastAgentExitCode: Int?, lastAgentExitSignal: String?,
        lastAgentExitAt: String?, lastAgentDisconnectReason: String?, historyEntries: Int,
        mcpServers: [McpServerConfig]? = nil
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
        self.mcpServers = mcpServers
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
