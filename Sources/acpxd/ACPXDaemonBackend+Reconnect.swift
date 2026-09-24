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
    /// — while a turn may fall back to a new one. A control names what it `replacing`,
    /// which the replay then leaves alone (``ReconnectReplay/Replacing``).
    ///
    /// Entries are keyed by the stable `acpxRecordId`: the ACP session behind a record
    /// can change — a fallback replaces it, and the record moves to the new one — while
    /// the record stays the same.
    ///
    /// What connecting changes in the record — the session it moved to, what that
    /// session advertises, what the replay put back — goes to it in one change, and
    /// only once the replay succeeded. A turn in flight passes `onRecordChange`: it
    /// saves the record it holds, so the change goes to it. Otherwise the record is
    /// written here.
    ///
    /// A turn also passes `onConnectOutput`, which gets what connecting a new agent put
    /// on the wire once it is connected — or once connecting it failed (see
    /// ``ConnectOutputBuffer``). An agent already held has nothing to show.
    ///
    /// `handlers` answer what the agent asks of the client — the caller's permissions —
    /// and `terminalOutputCeiling` caps the output of the terminals it creates, `nil`
    /// being no cap: the calling CLI's `ACPX_TERMINAL_MAX_OUTPUT_BYTES`, which acpx reads
    /// in the process that connects the session. Both apply before anything is asked
    /// of the agent: it can start a command while it answers `initialize`, a load, or a
    /// replayed mode. Without `handlers` everything is approved.
    ///
    /// A turn run with `--model` passes it as `requestedModel`: the replay then leaves
    /// the saved model and options alone, which the turn replaces, and a session the
    /// reconnect has to start is started on that model, as acpx's queue owner does
    /// with the options it was started with.
    func ensure(
        recordId: String, agentCommand: String, cwd rawCwd: String, mcpServers: [McpServerConfig]?,
        control: Bool = false, handlers: ACPClientHandlers? = nil, terminalOutputCeiling: Int? = nil,
        replacing: ReconnectReplay.Replacing? = nil, requestedModel: String? = nil,
        onRecordChange: RecordChangeHandler? = nil, onConnectOutput: ConnectOutputHandler? = nil
    ) async throws -> Live {
        try await connect(
            recordId: recordId, agentCommand: agentCommand, cwd: rawCwd, mcpServers: mcpServers,
            control: control, handlers: handlers, terminalOutputCeiling: terminalOutputCeiling,
            replacing: replacing, requestedModel: requestedModel,
            onRecordChange: onRecordChange, onConnectOutput: onConnectOutput
        ).entry
    }

    /// ``ensure(recordId:agentCommand:cwd:mcpServers:control:handlers:terminalOutputCeiling:replacing:requestedModel:onRecordChange:onConnectOutput:)``,
    /// also saying whether the session had to be taken back — acpx's `resumed`: the
    /// agent was launched and `session/load` or `session/resume` got the session back.
    /// A session already held, or one a new session replaced, was not.
    func connect(
        recordId: String, agentCommand: String, cwd rawCwd: String, mcpServers: [McpServerConfig]?,
        control: Bool = false, handlers: ACPClientHandlers? = nil, terminalOutputCeiling: Int? = nil,
        replacing: ReconnectReplay.Replacing? = nil, requestedModel: String? = nil,
        onRecordChange: RecordChangeHandler? = nil, onConnectOutput: ConnectOutputHandler? = nil
    ) async throws -> (entry: Live, resumed: Bool) {
        let handlers = handlers ?? .standard(permission: .approveAll)
        let replacing = replacing ?? (requestedModel == nil ? nil : .configOption("model"))
        let sessionSpecs = try mcpServers.map { try $0.map { try $0.protocolSpec() } }
        var replacesExitedAgent = false
        while let existing = live[recordId] {
            if await !existing.agent.connection.isClosed {
                guard existing.sessionSpecs == sessionSpecs else {
                    throw DaemonError.mcpConfigConflict(recordId)
                }
                // acpx replays nothing onto a session its client still holds.
                await existing.agent.connection.setHandlers(handlers)
                await existing.agent.setTerminalOutputCeiling(terminalOutputCeiling)
                return (existing, false)
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
        let capabilities = record?.acpx?.clientCapabilities?.advertised ?? .acpx
        // What to put back is read now, before connecting changes anything — acpx takes
        // the desired mode, model and options at the start of `connectAndLoadSession`.
        let original = record?.acpx
        let desired = ReconnectReplay.Desired(original, replacing: replacing)
        let launch = config.agentLaunch(for: agentCommand)
        let command = launch.command
        let connectOutput = onConnectOutput.map { _ in ConnectOutputBuffer() }
        // What connecting shows goes out once it is over, however it went: acpx flushes
        // its buffer when connecting fails too, so the agent's refusal is on screen.
        let showConnectOutput = { (fellBack: Bool) in
            guard let connectOutput, let onConnectOutput else { return }
            await onConnectOutput(connectOutput.flush(fellBack: fellBack))
        }
        let handle: ACPAgent
        do {
            // The argv the session recorded (`agent_argv`) launches it as it was launched;
            // without one, its command line is split.
            handle = try await ACPAgent.launch(
                agent: command, argv: record?.agentArgv ?? launch.argv, cwd: cwd, handlers: handlers,
                capabilities: capabilities,
                authCredentials: config.auth, authPolicy: config.authPolicy,
                inheritStderr: inheritAgentStderr, terminalOutputCeiling: .given(terminalOutputCeiling),
                onRawWire: connectOutput?.observer)
        } catch {
            await showConnectOutput(false)
            throw error
        }
        let session: ACPSession
        let loaded: ReconnectReplay.Loaded
        // The record's `acpx` as connecting leaves it: what the session reports, then
        // what the replay put back.
        var state = original
        do {
            (session, loaded) = try await takeBackOrStartOver(
                handle, recordId: recordId, sessionId: record?.acpSessionId ?? recordId, cwd: cwd,
                specs: specs, command: command, sameSessionOnly: control && replacesExitedAgent,
                requestedModel: requestedModel)
            ReconnectReplay.applyLoaded(loaded, to: &state)
            let outcome = try await ReconnectReplay.replay(
                desired, replacing: replacing, original: original, loaded: loaded, state: &state,
                connection: handle.connection, agentCommand: command)
            ReconnectReplay.applyReconnectedModelState(
                outcome.models, configOptionsPresent: outcome.configOptionsPresent,
                legacyModelMetadataPresent: loaded.legacyModelMetadataPresent,
                createdFreshSession: loaded.createdFreshSession, to: &state)
        } catch {
            handle.rawWire.set(nil)
            await showConnectOutput(false)
            // Nothing will hold this agent: don't leave its process running. A failed
            // replay leaves the record as it was, on the session it had (acpx's
            // `settleFailedReplay`), and the next turn connects again.
            await handle.close()
            throw error
        }
        // The session the record is on from now on, and the agent's own id for it
        // (acpx's `reconcileAgentSessionId`), with what connecting left in `acpx`.
        let sessionId = session.id
        let agentSessionId = AgentSessionId.extract(from: session.meta)
        let connected = state
        // acpx writes the agent's lifecycle as soon as its client has started.
        await apply({ [handle] record in
            record.acpSessionId = sessionId
            record.reconcileAgentSessionId(agentSessionId)
            record.acpx = connected
            record.applyLifecycle(handle.lifecycle)
        }, to: recordId, via: onRecordChange)
        let entry = Live(agent: handle, session: session, sessionSpecs: sessionSpecs)
        live[recordId] = entry
        handle.rawWire.set(nil)
        let fellBack = loaded.createdFreshSession
        await showConnectOutput(fellBack)
        // Taken back unless a new session had to replace it.
        return (entry, !fellBack)
    }

    /// Gets what connecting an agent for a turn put on the wire, as acpx shows it.
    typealias ConnectOutputHandler = @Sendable ([WireMessageEvent]) async -> Void

    /// A change a reconnect makes to the record, and where a turn in flight takes it.
    typealias RecordChange = @Sendable (inout SessionRecord) -> Void
    typealias RecordChangeHandler = @Sendable (@escaping RecordChange) async -> Void

    /// Apply a reconnect's change: to the record a turn in flight saves, through
    /// `onRecordChange`, else to the stored record here.
    private func apply(
        _ change: @escaping RecordChange, to recordId: String, via onRecordChange: RecordChangeHandler?
    ) async {
        if let onRecordChange {
            await onRecordChange(change)
        } else {
            recordChange(recordId: recordId, change)
        }
    }

    /// A reconnect's change, when no turn holds the record.
    private func recordChange(recordId: String, _ change: RecordChange) {
        guard var record = findRecord(recordId) else { return }
        change(&record)
        do {
            try SessionStore.writeRecord(record)
        } catch {
            reconnectLog.warning("session record write failed after a reconnect: \(error)")
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
    /// Returns the session, and how it came back.
    private func takeBackOrStartOver(
        _ handle: ACPAgent, recordId: String, sessionId: String, cwd: String, specs: [MCPServerSpec],
        command: String, sameSessionOnly: Bool, requestedModel: String?
    ) async throws -> (session: ACPSession, loaded: ReconnectReplay.Loaded) {
        do {
            // The history a `session/load` replays is the record's already: acpx neither
            // shows nor records it when it reconnects.
            let session = try await handle.reconnectSession(
                id: sessionId, cwd: cwd, mcpServers: specs, suppressReplayUpdates: true)
            return (session, ReconnectReplay.Loaded(
                sessionId: session.id, createdFreshSession: false, configOptions: session.configOptions,
                models: session.models))
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
            // record — with a turn's `--model` over them. `session/load` and
            // `session/resume` carry no `_meta` upstream.
            var options = record?.acpx?.sessionOptions
            if let requestedModel {
                options = options ?? SessionAcpxState.SessionOptions()
                options?.model = requestedModel
            }
            let session = try await handle.newSession(
                cwd: cwd, mcpServers: specs, meta: SessionMeta.build(options: options, agentCommand: command))
            return (session, ReconnectReplay.Loaded(
                sessionId: session.id, createdFreshSession: true, configOptions: session.configOptions,
                models: session.models))
        }
    }

    /// Why a reconnect failed, in the words acpx's refusal uses: the agent's own message
    /// rather than a description that repeats its code.
    private func reconnectReason(_ error: Error) -> String {
        if let acp = error as? JSONRPCErrorBody { return acp.message }
        return error.localizedDescription
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
