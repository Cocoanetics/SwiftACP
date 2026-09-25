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
        agentCommand: String, cwd: String, name: String?, mcpServers: [McpServerConfig]?
    ) async throws -> String
    func listSessions(agentCommand: String?) async -> [SessionSummary]
    func showSession(sessionId: String) async throws -> SessionDetail
    func sessionHistory(sessionId: String, limit: Int?) async throws -> [HistoryEntry]
    func setSessionMcpServers(
        sessionId: String, mcpServers: [McpServerConfig], restart: Bool
    ) async throws -> Bool
    func setMode(
        sessionId: String, modeId: String, nonInteractivePermissions: String?, terminalOutputCeiling: Int?
    ) async throws -> SessionControlResult
    func setConfigOption(
        sessionId: String, configId: String, value: String, nonInteractivePermissions: String?,
        terminalOutputCeiling: Int?
    ) async throws -> SessionControlResult
    func setModel(
        sessionId: String, modelId: String, nonInteractivePermissions: String?, terminalOutputCeiling: Int?
    ) async throws -> SessionControlResult
    func closeSession(sessionId: String) async throws -> Bool
    func pruneSessions(
        agentCommand: String?, olderThanDays: Int?, includeHistory: Bool, dryRun: Bool
    ) async -> PruneResult
    func runPrompt(
        sessionId: String, text: String, blocks: [PromptBlock]?, content: [JSONValue]?, wait: Bool,
        permissionMode: String?, nonInteractivePermissions: String?, streamWire: Bool,
        permissionPolicy: PermissionRules?, terminalOutputCeiling: Int?, model: String?
    ) async throws -> String
    func cancelSession(sessionId: String) async throws -> Bool
    func sessionStatus(sessionId: String) async -> LiveSessionStatus
}

extension ACPXBackend {
    /// A backend that holds no agents live holds none of its sessions.
    public func sessionStatus(sessionId: String) async -> LiveSessionStatus {
        LiveSessionStatus(live: false)
    }
}
