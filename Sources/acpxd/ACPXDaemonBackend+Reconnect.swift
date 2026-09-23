import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

// Getting a session live again: the daemon holds one agent per session, so every
// control and every turn funnels through `ensure` — spawn or reuse, reconnect or fall
// back to a fresh session, then put back the selections the record remembers.
//
// Split from `ACPXDaemonBackend.swift` to keep that file inside the 500-line limit;
// these are internal rather than private so both halves can reach them.
extension ACPXDaemonBackend {
    func ensure(
        sessionId: String, agentCommand: String, cwd rawCwd: String, mcpServers: [McpServerConfig]?
    ) async throws -> Live {
        let sessionSpecs = try mcpServers.map { try $0.map { try $0.protocolSpec() } }
        if let existing = live[sessionId] {
            guard existing.sessionSpecs == sessionSpecs else {
                throw DaemonError.mcpConfigConflict(sessionId)
            }
            return existing
        }
        let cwd = try resolveCwd(rawCwd)
        // Resolve config for this cwd so the agent gets the same injected `auth`
        // credentials / auth policy (and config-alias resolution) the CLI applies.
        let config = try ConfigLoader.load(cwd: cwd)
        let specs = try sessionSpecs ?? config.mcpServerSpecs()
        let handle = try await ACPAgent.launch(
            agent: launchCommand(for: agentCommand, config: config), cwd: cwd, permission: .approveAll,
            authCredentials: config.auth, authPolicy: config.authPolicy,
            inheritStderr: inheritAgentStderr)
        let session: ACPSession
        do {
            session = try await handle.reconnectSession(id: sessionId, cwd: cwd, mcpServers: specs)
        } catch {
            let response = try await handle.connection.newSession(
                NewSessionRequest(cwd: cwd, mcpServers: specs))
            session = ACPSession(id: response.sessionId, agent: handle, modes: response.modes)
        }
        let entry = Live(agent: handle, session: session, sessionSpecs: sessionSpecs)
        live[sessionId] = entry
        await restoreSelections(for: sessionId, on: entry)
        return entry
    }

    /// Re-apply the selections the record remembers, so reconnecting does not silently
    /// drop them: a daemon restart, an adapter exit or a fresh-session fallback would
    /// otherwise leave a session on the agent's defaults while the record still claims
    /// the model the user pinned.
    ///
    /// The model goes first — a config option can depend on which model is selected,
    /// which is the order acpx applies them in (0.13.1, "re-apply a session-pinned model
    /// before set_mode/set_model/set_config_option after reconnect"). Each is
    /// best-effort: an agent that no longer offers a saved choice must not fail the turn
    /// that triggered the reconnect, and the record keeps the user's intent either way.
    func restoreSelections(for sessionId: String, on entry: Live) async {
        guard let acpx = findRecord(sessionId)?.acpx else { return }

        if let modelId = acpx.currentModelId {
            try? await entry.agent.connection.setModel(
                SetSessionModelRequest(sessionId: entry.session.id, modelId: modelId))
        }
        if let modeId = acpx.desiredModeId ?? acpx.currentModeId {
            try? await entry.session.setMode(modeId)
        }
        for (configId, value) in acpx.desiredConfigOptions ?? [:] {
            _ = try? await entry.agent.connection.setConfigOption(
                SetSessionConfigOptionRequest(
                    sessionId: entry.session.id, configId: configId, value: value))
        }
    }
    /// Expand and validate a caller-supplied working directory. MCP clients have no
    /// shell, so expand `~` ourselves (the CLI relies on the shell) and require the
    /// directory to exist — otherwise the agent fails with a cryptic internal error.
    func resolveCwd(_ rawCwd: String) throws -> String {
        let cwd = (rawCwd as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw DaemonError.invalidCwd(rawCwd)
        }
        return cwd
    }
}
