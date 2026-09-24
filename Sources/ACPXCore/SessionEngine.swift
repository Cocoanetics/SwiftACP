import Foundation
import JSONFoundation
import SwiftACP

/// The shared session-creation engine used by both the `acpx` CLI and the
/// `acpxd` daemon, so a session is persisted identically however it's created.
///
/// This is the faithful core of acpx's `createSession`: spawn the agent, create
/// an ACP session, capture its model/config state, then close the agent (an
/// ephemeral spawn — acpx reconnects later via `session/load`) and write the
/// record to `~/.acpx/sessions`.
public enum SessionEngine {
    /// Create a session for `agentCommand` rooted at `cwd`, persist its record,
    /// and return it. The agent is closed before returning (ephemeral spawn).
    ///
    /// - Parameters:
    ///   - mcpServers: the cwd's config-file servers for `session/new` (re-derived
    ///     from config on every later reconnect, so not persisted).
    ///   - sessionMcpServers: the session's *own* servers (`--mcp-config`, or the
    ///     daemon's `newSession(mcpServers:)`). When given they replace
    ///     `mcpServers` on the request and are persisted under the `acpx` state
    ///     block so every reconnect replays them.
    ///   - sessionOptions: per-session options (model, allowed tools, …) to record
    ///     under the `acpx` state block, or `nil` to leave them unset.
    ///   - meta: optional `_meta` for the `session/new` request (e.g. claude model).
    public static func createSession(
        agentCommand: String,
        agentArgv: [String]? = nil,
        cwd: String,
        name: String?,
        permission: PermissionPolicy,
        permissionRules: PermissionRules? = nil,
        authCredentials: [String: String],
        authPolicy: String,
        mcpServers: [MCPServerSpec] = [],
        sessionMcpServers: [McpServerConfig]? = nil,
        meta: JSONValue? = nil,
        sessionOptions: SessionAcpxState.SessionOptions? = nil,
        capabilities: ClientCapabilities = .acpx,
        inheritStderr: Bool = false,
        onModelWarning: ((String) -> Void)? = nil
    ) async throws -> SessionRecord {
        // Validate the session's own servers before paying for a spawn.
        let requestServers = try sessionMcpServers.map { try $0.map { try $0.protocolSpec() } }
            ?? mcpServers
        let handle = try await ACPAgent.launch(
            agent: agentCommand, argv: agentArgv, cwd: cwd, permission: permission, permissionRules: permissionRules,
            capabilities: capabilities,
            environment: AgentEnvironment.forAgent(authCredentials: authCredentials, sessionEnv: sessionOptions?.env),
            authCredentials: authCredentials, authPolicy: authPolicy,
            inheritStderr: inheritStderr)
        do {
            let response = try await handle.connection.newSession(
                NewSessionRequest(cwd: cwd, mcpServers: requestServers, meta: meta))
            // acpx's `createFreshSessionState`: the requested model goes on the new
            // session through whichever control it advertises — or, not advertised,
            // fails the creation.
            let advertised = ModelSupport.modelState(fromConfigOptions: response.configOptions)
                ?? ModelSupport.modelState(fromLegacyModels: response.models)
            let application = try await ModelApplication.applyRequestedModel(
                connection: handle.connection, sessionId: response.sessionId,
                requestedModel: sessionOptions?.model, models: advertised, agentCommand: agentCommand,
                onWarning: onModelWarning)
            let started = nowISO()
            var record = SessionRecord(
                acpxRecordId: response.sessionId, acpSessionId: response.sessionId,
                agentCommand: agentCommand, cwd: cwd, name: name,
                createdAt: started, lastUsedAt: started)
            record.agentSessionId = AgentSessionId.extract(from: response.meta)
            record.agentArgv = agentArgv
            record.closed = false
            record.protocolVersion = handle.initializeResult.protocolVersion
            record.agentCapabilities = handle.initializeResult.agentCapabilities.flatMap { caps in
                (try? JSONEncoder().encode(caps)).flatMap {
                    try? JSONDecoder().decode(JSONValue.self, from: $0)
                }
            }
            record.title = nil

            var acpx = SessionAcpxState()
            ModelSupport.applySessionModelState(
                configOptions: response.configOptions, models: response.models, to: &acpx)
            ModelSupport.applyInitialModelSelection(
                application, requestedModel: sessionOptions?.model, originalModels: advertised, to: &acpx)
            if let sessionOptions { acpx.sessionOptions = sessionOptions }
            acpx.mcpServers = sessionMcpServers
            // What `--no-fs` / `--no-terminal` withheld has to outlive this ephemeral
            // spawn: the daemon reconnects later and must advertise the same, or the
            // restriction would silently lapse on the very turns it exists to cover.
            acpx.clientCapabilities = capabilities.persistedIfRestricted
            record.acpx = acpx

            // Ephemeral spawn: acpx closes the agent's stdin, so it exits on EOF
            // (a graceful connection close, not a kill).
            await handle.close()
            record.pid = nil
            record.agentStartedAt = started
            record.lastAgentExitCode = .null
            record.lastAgentExitSignal = .null
            record.lastAgentExitAt = nowISO()
            record.lastAgentDisconnectReason = "connection_close"

            try SessionStore.writeRecord(record)
            return record
        } catch {
            await handle.close()
            throw error
        }
    }
}
