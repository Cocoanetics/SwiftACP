import ACPXCore
import Foundation
import JSONFoundation
import Logging
import SwiftACP

// Getting a session live again: the daemon holds one agent per session, so every
// control and every turn funnels through `ensure` — spawn or reuse, reconnect or fall
// back to a fresh session, then put back the selections the record remembers.
//
// Split from `ACPXDaemonBackend.swift` to keep that file inside the 500-line limit;
// these are internal rather than private so both halves can reach them.
extension ACPXDaemonBackend {
    /// Return the live entry for `sessionId`, launching the agent and reconnecting
    /// if needed. When the agent no longer knows the session, fall back to a fresh
    /// `session/new` on the same launch, still keyed under the caller's session id.
    ///
    /// This is the one place a connection is made, so it is where the session's MCP
    /// servers are resolved — like npm acpx's runtime, which resolves them "at
    /// connection creation with the session's stored identity". `mcpServers` is the
    /// record's own set; `nil` falls back to the cwd's config-file servers. A held
    /// connection keeps the set it was made with, so a record that now asks for a
    /// different one is refused rather than silently served with the old servers.
    ///
    /// A held agent that has exited is not reused: its entry is dropped and the session
    /// reconnected, as acpx's queue owner starts a new client once `hasLiveConnection`
    /// is false. A `control` (mode, model, config option) that has to do that must get
    /// the *same* session back — acpx runs an idle owner's controls `same-session-only`
    /// — while a turn may fall back to a new one.
    ///
    /// Entries are keyed by the stable `acpxRecordId`: the ACP session behind a record
    /// can change — a fallback replaces it, and the record moves to the new one — while
    /// the record stays the same.
    ///
    /// A turn in flight passes `onReplacement`: it saves the record it holds, so a
    /// replacement goes to it, and it writes the record. Otherwise the record is
    /// written here.
    ///
    /// A turn also passes `onConnectOutput`, which gets what connecting a new agent put
    /// on the wire once it is connected — or once connecting it failed (see
    /// ``ConnectOutputBuffer``). An agent already held has nothing to show.
    func ensure(
        recordId: String, agentCommand: String, cwd rawCwd: String, mcpServers: [McpServerConfig]?,
        control: Bool = false, onReplacement: ReplacementHandler? = nil,
        onConnectOutput: ConnectOutputHandler? = nil
    ) async throws -> Live {
        let sessionSpecs = try mcpServers.map { try $0.map { try $0.protocolSpec() } }
        var replacesExitedAgent = false
        while let existing = live[recordId] {
            if await !existing.agent.connection.isClosed {
                guard existing.sessionSpecs == sessionSpecs else {
                    throw DaemonError.mcpConfigConflict(recordId)
                }
                return existing
            }
            replacesExitedAgent = true
            // Re-checked after the suspension above: only drop the entry that died.
            if live[recordId]?.agent === existing.agent { live.removeValue(forKey: recordId) }
            await existing.agent.close()
        }
        let cwd = try resolveCwd(rawCwd)
        // Resolve config for this cwd so the agent gets the same injected `auth`
        // credentials / auth policy (and config-alias resolution) the CLI applies.
        let config = try ConfigLoader.load(cwd: cwd, ownMcpServers: sessionSpecs != nil)
        let specs = try sessionSpecs ?? config.mcpServerSpecs()
        // A session created under `--no-fs` / `--no-terminal` keeps those restrictions:
        // the record carries them, so every reconnect advertises what the session was
        // created with rather than the defaults.
        let record = findRecord(recordId)
        let capabilities = record?.acpx?.clientCapabilities?.advertised ?? .headlessController
        // What to put back is read now, before a replacement session's advertised state
        // lands on the record — acpx takes the desired mode, model and options at the
        // start of `connectAndLoadSession` for the same reason.
        let selections = record?.acpx
        let command = launchCommand(for: agentCommand, config: config)
        let connectOutput = onConnectOutput.map { _ in ConnectOutputBuffer() }
        // What connecting shows goes out once it is over, however it went: acpx flushes
        // its buffer when connecting fails too, so the agent's refusal is on screen.
        let showConnectOutput = { (fellBack: Bool) in
            guard let connectOutput, let onConnectOutput else { return }
            await onConnectOutput(connectOutput.flush(fellBack: fellBack))
        }
        let handle: ACPAgent
        do {
            handle = try await ACPAgent.launch(
                agent: command, cwd: cwd, permission: .approveAll,
                capabilities: capabilities,
                authCredentials: config.auth, authPolicy: config.authPolicy,
                inheritStderr: inheritAgentStderr, onRawWire: connectOutput?.observer)
        } catch {
            await showConnectOutput(false)
            throw error
        }
        let session: ACPSession
        let fellBack: Bool
        do {
            let reconnected = try await takeBackOrStartOver(
                handle, recordId: recordId, sessionId: record?.acpSessionId ?? recordId, cwd: cwd,
                specs: specs, command: command, sameSessionOnly: control && replacesExitedAgent)
            session = reconnected.session
            fellBack = reconnected.replacement != nil
            // Settled before the replay below: while it runs, a turn could save the
            // record it holds, and with the old session that save would undo this.
            if let replacement = reconnected.replacement {
                if let onReplacement {
                    await onReplacement(replacement)
                } else {
                    recordReplacement(recordId: recordId, response: replacement)
                }
            }
        } catch {
            handle.rawWire.set(nil)
            await showConnectOutput(false)
            // Nothing will hold this agent: don't leave its process running.
            await handle.close()
            throw error
        }
        let entry = Live(agent: handle, session: session, sessionSpecs: sessionSpecs)
        live[recordId] = entry
        await restoreSelections(selections, on: entry)
        handle.rawWire.set(nil)
        await showConnectOutput(fellBack)
        return entry
    }

    /// Gets what connecting an agent for a turn put on the wire, as acpx shows it.
    typealias ConnectOutputHandler = @Sendable ([WireMessageEvent]) async -> Void

    /// Takes a reconnect's replacement session — its `session/new` response — onto the
    /// record a turn in flight will save.
    typealias ReplacementHandler = @Sendable (NewSessionResponse) async -> Void

    /// The session a fallback started is the record's session from now on: acpx moves
    /// `acpSessionId` to it (keeping `acpxRecordId`) along with what it advertised, so
    /// the next reconnect asks for this one — not the one that was already gone.
    private func recordReplacement(recordId: String, response: NewSessionResponse) {
        guard var record = findRecord(recordId) else { return }
        record.moveToReplacement(
            sessionId: response.sessionId, configOptions: response.configOptions, models: response.models)
        do {
            try SessionStore.writeRecord(record)
        } catch {
            reconnectLog.warning("session record write failed after a fresh-session fallback: \(error)")
        }
    }

    /// Take the session back on a fresh launch, or start a new one in its place —
    /// acpx's `loadRuntimeSession` / `recoverRuntimeSessionLoadFailure`.
    ///
    /// The agent is asked the way it says it can be (``ACPAgent/reconnectSession``). If
    /// it cannot take the session back, a new one is started only when that loses
    /// nothing worth keeping (``ReconnectFallback``); otherwise the failure is surfaced
    /// rather than silently swapping the conversation for an empty one under the same
    /// id. A session imported from another client must stay the *same* session, so it
    /// is never replaced — acpx's `sameSessionOnly` — and neither is one the caller
    /// asks to keep (`sameSessionOnly`).
    ///
    /// Returns the session, and the `session/new` response when it is a replacement.
    private func takeBackOrStartOver(
        _ handle: ACPAgent, recordId: String, sessionId: String, cwd: String, specs: [MCPServerSpec],
        command: String, sameSessionOnly: Bool
    ) async throws -> (session: ACPSession, replacement: NewSessionResponse?) {
        do {
            // The history a `session/load` replays is the record's already: acpx neither
            // shows nor records it when it reconnects.
            let session = try await handle.reconnectSession(
                id: sessionId, cwd: cwd, mcpServers: specs, suppressReplayUpdates: true)
            return (session, nil)
        } catch {
            let record = findRecord(recordId)
            switch ReconnectFallback.outcome(
                after: error, sameSessionOnly: sameSessionOnly || record?.importedFrom != nil,
                sessionHasAgentMessages: record?.hasAgentMessages ?? false) {
            case .surface: throw error
            case .refuse: throw DaemonError.sessionResumeRequired(sessionId, reason: reconnectReason(error))
            case .startFresh: break
            }
            // Falling back is a `session/new`, and a `session/new` carries the
            // session's options as `_meta` — acpx builds every `createSession` from
            // the options its client was made with, which on a reconnect come from the
            // record. `session/load` and `session/resume` carry no `_meta` upstream.
            let response = try await handle.connection.newSession(
                NewSessionRequest(
                    cwd: cwd, mcpServers: specs,
                    meta: SessionMeta.build(
                        options: record?.acpx?.sessionOptions, agentCommand: command)))
            return (ACPSession(id: response.sessionId, agent: handle, modes: response.modes), response)
        }
    }

    /// Why a reconnect failed, in the words acpx's refusal uses: the agent's own message
    /// rather than a description that repeats its code.
    private func reconnectReason(_ error: Error) -> String {
        if let acp = error as? JSONRPCErrorBody { return acp.message }
        return error.localizedDescription
    }

    /// Re-apply the selections the record remembers, so reconnecting does not silently
    /// drop them: a daemon restart, an adapter exit or a fresh-session fallback would
    /// otherwise leave a session on the agent's defaults while the record still claims
    /// the model the user pinned.
    ///
    /// The model goes first — a config option can depend on which model is selected,
    /// which is the order acpx applies them in (0.13.1, "re-apply a session-pinned model
    /// before set_mode/set_model/set_config_option after reconnect"). Which request
    /// carries the model depends on how the agent exposes it: adapters that advertise it
    /// as a config option keep the choice in `desired_config_options` under that
    /// option's id, and `current_model_id` can still hold the advertised default — so
    /// the option is sent first and skipped when the rest are replayed, rather than
    /// arriving somewhere in the middle of an unordered dictionary.
    ///
    /// Each is best-effort: an agent that no longer offers a saved choice must not fail
    /// the turn that triggered the reconnect, and the record keeps the user's intent
    /// either way.
    func restoreSelections(_ selections: SessionAcpxState?, on entry: Live) async {
        guard let acpx = selections else { return }
        let desiredOptions = acpx.desiredConfigOptions ?? [:]
        // The record keeps the agent's advertised options verbatim; the model's option
        // id is derived from them the same way `session/new` derived it.
        var advertised: [JSONValue]?
        if case .array(let options)? = acpx.configOptions { advertised = options }
        let modelConfigId = ModelSupport.modelState(fromConfigOptions: advertised)?.configId

        if let modelConfigId, let modelValue = desiredOptions[modelConfigId] {
            await apply(configId: modelConfigId, value: modelValue, on: entry)
        } else if let modelId = acpx.currentModelId, acpx.modelControl != "config_option" {
            try? await entry.agent.connection.setModel(
                SetSessionModelRequest(sessionId: entry.session.id, modelId: modelId))
        }
        if let modeId = acpx.desiredModeId ?? acpx.currentModeId {
            try? await entry.session.setMode(modeId)
        }
        // Sorted so a replay is reproducible; the model is already applied.
        for configId in desiredOptions.keys.sorted() where configId != modelConfigId {
            guard let value = desiredOptions[configId] else { continue }
            await apply(configId: configId, value: value, on: entry)
        }
    }

    private func apply(configId: String, value: String, on entry: Live) async {
        _ = try? await entry.agent.connection.setConfigOption(
            SetSessionConfigOptionRequest(
                sessionId: entry.session.id, configId: configId, value: value))
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

private let reconnectLog = Logger(label: "com.cocoanetics.acpx.acpxd.reconnect")
