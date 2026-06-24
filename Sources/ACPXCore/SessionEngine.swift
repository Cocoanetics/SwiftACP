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
    ///   - sessionOptions: per-session options (model, allowed tools, …) to record
    ///     under the `acpx` state block, or `nil` to leave them unset.
    ///   - meta: optional `_meta` for the `session/new` request (e.g. claude model).
    public static func createSession(
        agentCommand: String,
        cwd: String,
        name: String?,
        permission: PermissionPolicy,
        authCredentials: [String: String],
        authPolicy: String,
        meta: JSONValue? = nil,
        sessionOptions: SessionAcpxState.SessionOptions? = nil,
        inheritStderr: Bool = false
    ) async throws -> SessionRecord {
        let handle = try await ACPAgent.launch(
            agent: agentCommand, cwd: cwd, permission: permission,
            authCredentials: authCredentials, authPolicy: authPolicy,
            inheritStderr: inheritStderr)
        do {
            let response = try await handle.connection.newSession(
                NewSessionRequest(cwd: cwd, mcpServers: [], meta: meta))
            let started = nowISO()
            var record = SessionRecord(
                acpxRecordId: response.sessionId, acpSessionId: response.sessionId,
                agentCommand: agentCommand, cwd: cwd, name: name,
                createdAt: started, lastUsedAt: started)
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
            if let sessionOptions { acpx.sessionOptions = sessionOptions }
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
