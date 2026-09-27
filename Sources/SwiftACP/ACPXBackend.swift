import Foundation
import JSONFoundation

/// The backend that fulfills the acpx daemon's MCP tools — live agent sessions, the
/// persisted session store, prompt turns and their streaming.
///
/// The `@MCPServer` shell (``ACPXDaemon``) delegates every tool to an `ACPXBackend`.
/// `acpxd` provides the real, macOS-only implementation; the shell itself stays
/// portable (it references no `Foundation.Process`, filesystem, or serving APIs), so
/// its generated `ACPXDaemon.Client` compiles for an iOS MCP client that drives a
/// remote daemon and never links a backend.
///
/// `runPrompt` streams each `session/update` to the calling MCP client as a log
/// notification; because the backend runs inside the tool-dispatch task, it reaches
/// the serving session (`Session.current`) itself — the shell forwards nothing.
public protocol ACPXBackend: Sendable {
    func newSession(
        agentCommand: String, agentArgv: [String]?, cwd: String, name: String?, mcpServers: [McpServerConfig]?,
        sessionOptions: PromptSessionOptions?, creation: SessionCreationMode
    ) async throws -> String
    func listSessions(agentCommand: String?) async -> [SessionSummary]
    func showSession(sessionId: String) async throws -> SessionDetail
    func sessionHistory(sessionId: String, limit: Int?) async throws -> [HistoryEntry]
    func setSessionMcpServers(
        sessionId: String, mcpServers: [McpServerConfig], restart: Bool
    ) async throws -> Bool
    func setMode(
        sessionId: String, modeId: String, nonInteractivePermissions: String?, terminalOutputCeiling: Int?,
        timeoutMs: Int?
    ) async throws -> SessionControlResult
    func setConfigOption(
        sessionId: String, configId: String, value: String, nonInteractivePermissions: String?,
        terminalOutputCeiling: Int?, timeoutMs: Int?
    ) async throws -> SessionControlResult
    func setModel(
        sessionId: String, modelId: String, nonInteractivePermissions: String?, terminalOutputCeiling: Int?,
        timeoutMs: Int?
    ) async throws -> SessionControlResult
    func closeSession(sessionId: String) async throws -> Bool
    func pruneSessions(
        agentCommand: String?, olderThanDays: Int?, includeHistory: Bool, dryRun: Bool
    ) async -> PruneResult
    func runPrompt(
        sessionId: String, text: String, blocks: [PromptBlock]?, content: [JSONValue]?, wait: Bool,
        permissionMode: String?, nonInteractivePermissions: String?, mode: PromptTurnMode,
        permissionPolicy: PermissionRules?, terminalOutputCeiling: Int?, sessionOptions: PromptSessionOptions?,
        limits: PromptLimits?
    ) async throws -> String
    func cancelSession(sessionId: String, turnToken: String?) async throws -> Bool
    func callOffCreation(creationToken: String) async throws -> Bool
    func sessionStatus(sessionId: String) async -> LiveSessionStatus
    func releaseSession(sessionId: String, turnToken: String?) async throws -> Bool
}

/// The config a caller read once, which a session's agents are started with in place of the
/// one where the session works: a flow's, as acpx's runner gives every client of its run the
/// invocation's `config.auth` and `config.mcpServers`, read as the run starts — whatever `cwd`
/// a node sets, and however the files change meanwhile.
public struct CallerConfig: Codable, Sendable, Equatable {
    /// The credentials, by auth method (`auth`).
    public var auth: [String: String]
    /// The MCP servers, sent to a session that has none of its own.
    public var mcpServers: [McpServerConfig]

    public init(auth: [String: String], mcpServers: [McpServerConfig]) {
        self.auth = auth
        self.mcpServers = mcpServers
    }
}

/// How a session is made, beside where and with what (``ACPXDaemon``'s `newSession`):
/// whether its agent is kept for its first turn (`holdAgent`), what that agent is offered
/// (`fs`, acpx's `--no-fs`), how its requests are answered until then — as a turn's are
/// (`permissionMode`, `nonInteractivePermissions`, `permissionPolicy`) — how it signs in
/// (`authPolicy`, acpx's `--auth-policy`; `nil`, as configured), the config it is started with
/// (`callerConfig`; `nil`, the one where the session works), whether what the agent writes
/// to stderr is streamed to the caller (`verbose`, acpx's `--verbose`), and the caller's name for
/// the creation, which ``ACPXBackend/callOffCreation(creationToken:)`` can give (`creationToken`).
public struct SessionCreationMode: Sendable {
    public var holdAgent: Bool
    public var fs: Bool?
    public var permissionMode: String?
    public var nonInteractivePermissions: String?
    public var permissionPolicy: PermissionRules?
    public var authPolicy: String?
    public var callerConfig: CallerConfig?
    public var verbose: Bool
    public var creationToken: String?

    public init(
        holdAgent: Bool = false, fs: Bool? = nil, permissionMode: String? = nil,
        nonInteractivePermissions: String? = nil, permissionPolicy: PermissionRules? = nil, authPolicy: String? = nil,
        callerConfig: CallerConfig? = nil, verbose: Bool = false, creationToken: String? = nil
    ) {
        self.holdAgent = holdAgent
        self.fs = fs
        self.permissionMode = permissionMode
        self.nonInteractivePermissions = nonInteractivePermissions
        self.permissionPolicy = permissionPolicy
        self.authPolicy = authPolicy
        self.callerConfig = callerConfig
        self.verbose = verbose
        self.creationToken = creationToken
    }
}

/// How a turn runs, beside what it sends: whether its whole exchange is streamed back
/// (``ACPXDaemon``'s `runPrompt` `streamWire`), whether it runs as acpx's
/// `sendSessionDirect` runs a flow's persistent turn (`direct`), whether an agent it
/// connects is offered the filesystem methods (`fs`, acpx's `--no-fs`; `nil`, as the
/// session was created), how that agent signs in (`authPolicy`, acpx's `--auth-policy`;
/// `nil`, as configured), the caller's name for the turn, which a cancel can give before it
/// begins (`turnToken`), the config that agent is started with (`callerConfig`; `nil`, the one
/// where the session works), and whether what the agent writes to stderr is streamed to the
/// caller (`verbose`, acpx's `--verbose`).
public struct PromptTurnMode: Sendable, Equatable {
    public var streamWire: Bool
    public var direct: Bool
    public var fs: Bool?
    public var authPolicy: String?
    public var turnToken: String?
    public var callerConfig: CallerConfig?
    public var verbose: Bool

    public init(
        streamWire: Bool = false, direct: Bool = false, fs: Bool? = nil, authPolicy: String? = nil,
        turnToken: String? = nil, callerConfig: CallerConfig? = nil, verbose: Bool = false
    ) {
        self.streamWire = streamWire
        self.direct = direct
        self.fs = fs
        self.authPolicy = authPolicy
        self.turnToken = turnToken
        self.callerConfig = callerConfig
        self.verbose = verbose
    }
}

extension ACPXBackend {
    /// A backend that holds no agents live holds none of its sessions.
    public func sessionStatus(sessionId: String) async -> LiveSessionStatus {
        LiveSessionStatus(live: false)
    }

    /// A backend that holds no agents live has none to let go.
    public func releaseSession(sessionId: String, turnToken: String?) async throws -> Bool {
        false
    }

    /// A backend that holds no agents live keeps none it made.
    public func callOffCreation(creationToken: String) async throws -> Bool {
        false
    }
}
