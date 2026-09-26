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
    ///   - meta: optional `_meta` for the `session/new` request (e.g. claude model), or
    ///     for the request that takes a session back.
    ///   - resumeSessionId: an ACP session to take back in place of a new one — acpx's
    ///     `--resume-session`. The record is written under its id.
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
        resumeSessionId: String? = nil,
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
            let target = Target(
                handle: handle, cwd: cwd, mcpServers: requestServers, meta: meta, model: sessionOptions?.model,
                agentCommand: agentCommand, onModelWarning: onModelWarning)
            let created: Created
            if let resumeSessionId {
                created = try await resume(resumeSessionId, on: target)
            } else {
                created = try await startSession(on: target)
            }
            let advertised = created.models
            let application = created.application
            let started = nowISO()
            var record = SessionRecord(
                acpxRecordId: created.sessionId, acpSessionId: created.sessionId,
                agentCommand: agentCommand, cwd: cwd, name: name,
                createdAt: started, lastUsedAt: started)
            record.agentSessionId = AgentSessionId.extract(from: created.meta)
            record.agentArgv = agentArgv
            record.closed = false
            record.protocolVersion = handle.initializeResult.protocolVersion
            record.agentCapabilities = handle.initializeResult.agentCapabilities.flatMap { caps in
                (try? JSONEncoder().encode(caps)).flatMap {
                    try? JSONDecoder().decode(JSONValue.self, from: $0)
                }
            }
            record.title = nil

            // In acpx's order (`createSessionRecordWithClient`): the session options on a new
            // block, then the options the session reported, then the model it was asked for.
            var acpx = SessionAcpxState()
            if let sessionOptions { acpx.sessionOptions = sessionOptions }
            ModelSupport.applyConfigOptions(created.configOptions, to: &acpx)
            ModelSupport.applyInitialModelSelection(
                application, requestedModel: sessionOptions?.model, originalModels: advertised, to: &acpx)
            acpx.mcpServers = sessionMcpServers
            // What `--no-fs` / `--no-terminal` withheld has to outlive this ephemeral
            // spawn: the daemon reconnects later and must advertise the same, or the
            // restriction would silently lapse on the very turns it exists to cover.
            acpx.clientCapabilities = capabilities.persistedIfRestricted
            record.acpx = acpx

            // Ephemeral spawn: acpx closes the agent's stdin, so it exits on EOF
            // (a graceful connection close, not a kill), and records how it went — the
            // connection closing, seen before the process exits.
            await handle.close()
            if let lifecycle = handle.lifecycle {
                record.applyLifecycle(lifecycle)
            } else {
                // Where the agent cannot be watched, what closing it records in acpx.
                record.pid = nil
                record.agentStartedAt = started
                record.lastAgentExitCode = .null
                record.lastAgentExitSignal = .null
                record.lastAgentExitAt = nowISO()
                record.lastAgentDisconnectReason = AgentDisconnectReason.connectionClose.rawValue
            }

            try SessionStore.writeRecord(record)
            return record
        } catch {
            await handle.close()
            throw error
        }
    }

    /// Where a creation gets its session, and the model it asks for.
    private struct Target {
        let handle: ACPAgent
        let cwd: String
        let mcpServers: [MCPServerSpec]
        let meta: JSONValue?
        let model: String?
        let agentCommand: String
        let onModelWarning: ((String) -> Void)?
    }

    /// The session a creation starts or takes back, and what applying the requested
    /// model to it came to: acpx's `CreatedSessionState`.
    private struct Created {
        let sessionId: String
        let meta: JSONValue?
        let configOptions: [JSONValue]?
        /// The models it advertises.
        let models: ModelSupport.ModelState?
        let application: ModelApplication.Application
    }

    /// acpx's `createFreshSessionState`: a new session, with the requested model put on
    /// it through whichever control it advertises; one not advertised fails the creation.
    private static func startSession(on target: Target) async throws -> Created {
        let response = try await target.handle.connection.newSession(
            NewSessionRequest(cwd: target.cwd, mcpServers: target.mcpServers, meta: target.meta))
        return try await applyingModel(
            to: response.sessionId, meta: response.meta, configOptions: response.configOptions,
            models: response.models, on: target)
    }

    /// acpx's `resumeSessionRecordWithClient`: the session taken back with `session/resume`
    /// when the agent advertises it, else `session/load`, with the requested model put on
    /// it. An agent that can do neither is refused before anything is sent; any other
    /// failure, the model's included, is the resume's.
    private static func resume(_ sessionId: String, on target: Target) async throws -> Created {
        let capabilities = target.handle.agentCapabilities
        guard capabilities?.sessionCapabilities?.supportsResume == true || capabilities?.loadSession == true else {
            throw SessionResumeUnsupported(agentCommand: target.agentCommand, sessionId: sessionId)
        }
        do {
            // Its history is the agent's to replay, and nothing here records it.
            let session = try await target.handle.reconnectSession(
                id: sessionId, cwd: target.cwd, mcpServers: target.mcpServers, meta: target.meta,
                suppressReplayUpdates: true)
            return try await applyingModel(
                to: sessionId, meta: session.meta, configOptions: session.configOptions, models: session.models,
                on: target)
        } catch {
            throw SessionResumeError(sessionId: sessionId, underlying: error)
        }
    }

    private static func applyingModel(
        to sessionId: String, meta: JSONValue?, configOptions: [JSONValue]?, models: JSONValue?, on target: Target
    ) async throws -> Created {
        let advertised = ModelSupport.modelState(fromConfigOptions: configOptions)
            ?? ModelSupport.modelState(fromLegacyModels: models)
        let application = try await ModelApplication.applyRequestedModel(
            connection: target.handle.connection, sessionId: sessionId, requestedModel: target.model,
            models: advertised, agentCommand: target.agentCommand, onWarning: target.onModelWarning)
        return Created(
            sessionId: sessionId, meta: meta, configOptions: configOptions, models: advertised,
            application: application)
    }
}

/// A resume that failed: acpx's `Failed to resume ACP session <id>: <why>`, the agent's
/// error kept as its cause.
public struct SessionResumeError: LocalizedError {
    public let sessionId: String
    public let underlying: any Error

    public var errorDescription: String? {
        "Failed to resume ACP session \(sessionId): \(TurnFailure.message(of: underlying))"
    }
}

/// acpx's refusal to resume a session with an agent that advertises neither
/// `session/resume` nor `session/load`.
public struct SessionResumeUnsupported: LocalizedError {
    public let agentCommand: String
    public let sessionId: String

    public var errorDescription: String? {
        "Agent command \"\(agentCommand)\" does not support session/resume or session/load; "
            + "cannot resume session \(sessionId)"
    }
}
