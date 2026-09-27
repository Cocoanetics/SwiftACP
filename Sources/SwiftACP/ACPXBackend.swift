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
        sessionOptions: PromptSessionOptions?, holdAgent: Bool, fs: Bool?
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
    func cancelSession(sessionId: String) async throws -> Bool
    func sessionStatus(sessionId: String) async -> LiveSessionStatus
    func releaseSession(sessionId: String) async throws -> Bool
}

/// How a turn runs, beside what it sends: whether its whole exchange is streamed back
/// (``ACPXDaemon``'s `runPrompt` `streamWire`), whether it runs as acpx's
/// `sendSessionDirect` runs a flow's persistent turn (`direct`), and whether an agent it
/// connects is offered the filesystem methods (`fs`, acpx's `--no-fs`; `nil`, as the
/// session was created).
public struct PromptTurnMode: Sendable, Equatable {
    public var streamWire: Bool
    public var direct: Bool
    public var fs: Bool?

    public init(streamWire: Bool = false, direct: Bool = false, fs: Bool? = nil) {
        self.streamWire = streamWire
        self.direct = direct
        self.fs = fs
    }
}

extension ACPXBackend {
    /// A backend that holds no agents live holds none of its sessions.
    public func sessionStatus(sessionId: String) async -> LiveSessionStatus {
        LiveSessionStatus(live: false)
    }

    /// A backend that holds no agents live has none to let go.
    public func releaseSession(sessionId: String) async throws -> Bool {
        false
    }
}
