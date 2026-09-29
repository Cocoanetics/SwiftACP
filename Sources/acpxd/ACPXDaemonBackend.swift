import ACPXCore
import Foundation
import JSONFoundation
import Logging
import SwiftACP
import SwiftMCP

/// The macOS implementation of the acpx daemon's MCP tools — the ``ACPXBackend`` the
/// ``ACPXDaemon`` `@MCPServer` shell delegates to.
///
/// It holds live ACP agent sessions so prompts across CLI invocations (and remote
/// MCP clients) reuse one adapter process instead of respawning, owns the singleton
/// lock, and drives the persisted session store. `runPrompt` streams each ACP
/// `session/update` to the calling MCP client as a log notification — reaching the
/// serving session (`Session.current`) directly, since the backend runs inside the
/// tool-dispatch task. Run as a `Service` (see ``AcpxdCommand``) so it closes its
/// agents and releases the lock on shutdown.
actor ACPXDaemonBackend: ACPXBackend {
    /// A live agent handle + its session, keyed by ACP session id in ``live``.
    /// Internal (not private) so the ``Service`` conformance in `AcpxdCommand` can
    /// close them on shutdown.
    struct Live {
        let agent: ACPAgent
        let session: ACPSession
        /// Where what a held agent writes to stderr waits for the next verbose call.
        var stderr: AgentStderrRelay?
        /// What the agent was given of the config of the caller it connected for.
        var configuration: AgentConfiguration?
    }

    /// What an agent is given of its caller's config as it connects: the MCP servers it is sent and
    /// the credentials it signs in with — each acpx client's own (#245).
    struct AgentConfiguration: Equatable, Sendable {
        let mcpServers: [MCPServerSpec]
        let auth: [String: String]
    }

    /// Live sessions held open between prompts, keyed by acpx record id.
    var live: [String: Live] = [:]
    /// Agents being connected, until held, by record: what a close past its grace puts
    /// down (``ConnectingAgent``).
    var connecting: [String: ConnectingAgent] = [:]
    /// Set once the daemon lets its agents go for good (``releaseAll()``): from then on
    /// no agent is started or held.
    var stopping = false

    /// Serializes prompt turns per session so concurrent CLI/MCP callers can't drive
    /// one agent — or persist one record — at the same time (see ``SessionTurnQueue``).
    /// Internal (not private) so the prompt turns in `ACPXDaemonBackend+Prompt.swift`
    /// can take a session's slot.
    let turnQueue = SessionTurnQueue()
    /// The turn each session's queue owner runs, by record: see ``TurnControl``.
    var turns: [String: TurnControl] = [:]
    /// The direct turns — a flow's — each session runs or has waiting for it, by record, in the
    /// order they began, outside its queue owner, as acpx's `sendSessionDirect` takes only the
    /// session's turn (#225). Only one has the session at a time.
    var directTurns: [String: [TurnControl]] = [:]
    /// The tokens of turns a cancel named before they began, and when: each ends as it
    /// begins (``claimTurnToken(_:for:)``).
    var calledOffTurns: [String: Date] = [:]
    /// The creation tokens a call-off named before their session was made, and the session each
    /// made, with when: see ``callOffCreation(creationToken:)``.
    var calledOffCreations: [String: Date] = [:]
    var madeCreations: [String: MadeCreation] = [:]
    /// The tokens of the creations under way, whose call-offs are kept however long they take.
    var creatingTokens: Set<String> = []
    /// The tokens of the turns waiting to begin, whose call-offs are kept however long they wait.
    var waitingTurnTokens: Set<String> = []
    /// The controls each prompt's turn takes while it runs, by record: see ``PromptControlTicket``.
    var tickets: [String: PromptControlTicket] = [:]
    /// Each session's prompts in line to begin, by record, while one has begun: see ``PromptLine``.
    var promptLines: [String: PromptLine] = [:]
    /// Monotonic source of tokens for the prompts waiting to begin.
    var nextPromptToken = 0
    /// The sessions being closed or let go, by record, with how many closes: no prompt begins
    /// meanwhile, as acpx's owner takes none once it shuts down.
    var shuttingDown: [String: Int] = [:]
    /// The sessions held as acpx's queue owner holds one, by record: see ``SessionOwner``.
    var owners: [String: SessionOwner] = [:]
    /// The MCP config each session's owner will have, by record, while none holds it yet: see
    /// ``OwnerConfigClaim``.
    var ownerConfigClaims: [String: OwnerConfigClaim] = [:]
    /// For tests: run as a turn's prompt is about to be written, once a cancel can no
    /// longer keep it from going out.
    var promptGoingOut: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once a turn's prompt is answered, before the turn first looks at
    /// how many requests the agent has made.
    var beforeReplyDrain: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run each time a turn's updates have gone quiet past its answer, before
    /// it looks for requests of the agent's.
    var afterUpdateDrain: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once the pause before a retry has begun, which a cancel from then on
    /// cuts short.
    var retryPaused: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once a session's owner has stopped, its agent closed and its record
    /// written.
    var ownerStopped: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once connecting has moved the record to what it connected, before
    /// the agent is held.
    var reconnected: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once an owned control's deadline has passed, before what it connects
    /// or runs on is put down.
    var deadlinePassed: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once a control over past its deadline begins to wait for what that
    /// deadline puts down.
    var controlOverdue: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once a control sent during a prompt is taken on the prompt's ticket,
    /// before it waits for the prompt to go out.
    var controlTakenDuringPrompt: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once a prompt's turn has sealed its controls, before the turn is over.
    var controlsSealed: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: run once a close or a let-go has sent the cancel of a prompt that was out,
    /// before it sends the next.
    var cancelSent: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: told the record id whenever a prompt waits to begin behind another.
    var promptWaits: (@Sendable (_ recordId: String) -> Void)?
    /// For tests: run once a flow's new session is held, before its call-off is looked for.
    var creationKept: (@Sendable (_ recordId: String) async -> Void)?
    /// For tests: handed each note that a turn's prompt went out, as the writer's thread
    /// tells it, in place of bringing the note to the backend: it comes once the test runs
    /// it, if ever — as late as its task can come under load.
    var promptNoted: (@Sendable (_ recordId: String, _ note: @escaping @Sendable () async -> Void) async -> Void)?

    let log = Logger(label: "com.cocoanetics.acpx.acpxd.backend")

    /// When true, spawned agents inherit the daemon's stderr — surfacing agent
    /// diagnostics (e.g. rate-limit messages) that otherwise stay hidden.
    let inheritAgentStderr: Bool

    /// The singleton lock the daemon holds for its lifetime and releases on a graceful
    /// shutdown (nil in tests that don't exercise the lifecycle). Released by the
    /// ``Service`` conformance in `AcpxdCommand`.
    let lock: DaemonLock?

    init(inheritAgentStderr: Bool = false, lock: DaemonLock? = nil) {
        self.inheritAgentStderr = inheritAgentStderr
        self.lock = lock
    }

    /// Create a new session for an agent, persist its `~/.acpx/sessions` record
    /// (the same record the CLI's `sessions new` writes), and return its id.
    ///
    /// The session id is then used with ``runPrompt(sessionId:text:)``, which
    /// reconnects and holds the adapter live across prompts.
    ///
    /// - Parameters:
    ///   - agentCommand: the agent adapter to launch — a built-in name (`claude`,
    ///     `codex`), a config-defined agent alias, or a full command line. The
    ///     resolved launch command is stored on the session.
    ///   - cwd: the working directory the agent runs in (`~` is expanded).
    ///   - name: an optional session label (like `sessions new --name`); blank = none.
    ///   - mcpServers: the MCP servers the creating agent is given, in place of those of the
    ///     caller's config or the cwd's; the record keeps none, as acpx keeps none (#245).
    ///   - agentArgv: the argv the caller resolved for `agentCommand`, which is then taken as
    ///     it is; `nil` to resolve and split the command here.
    ///   - sessionOptions: the session's options, recorded and sent as `_meta`.
    ///   - creation: how the session is made (``SessionCreationMode``): its agent kept for
    ///     its first turn (`holdAgent`), `fs` — `false` withholds the filesystem methods from
    ///     the creating agent, and records it unless that agent is held (a flow says it with
    ///     each turn) — how the agent's requests are answered meanwhile, as a turn's are —
    ///     the config it is started with, and whether what it writes to stderr goes to the
    ///     caller (`verbose`).
    /// - Returns: the new session's acpx record id.
    func newSession(
        agentCommand: String, agentArgv: [String]?, cwd rawCwd: String, name: String?,
        mcpServers: [McpServerConfig]?, sessionOptions promptOptions: PromptSessionOptions?,
        creation: SessionCreationMode
    ) async throws -> String {
        let (holdAgent, fs) = (creation.holdAgent, creation.fs)
        // The agent's requests while the session is made are answered by the caller's mode and
        // rules — a flow's own, as acpx's runner makes its client with them.
        let handlers = try TurnPermissions(
            mode: creation.permissionMode, nonInteractive: creation.nonInteractivePermissions,
            rules: creation.permissionPolicy).handlers
        // A session held for a flow's first turn is made where it is asked for, as acpx's
        // `createSessionWithClient` makes it: a working directory that is not there fails
        // the agent's launch.
        let cwd = holdAgent ? ACPXPaths.resolve(rawCwd, base: FileManager.default.currentDirectoryPath)
            : try resolveCwd(rawCwd)
        // The caller's config — a flow's, read once, as acpx's runner gives every client of the
        // run the invocation's `auth` and MCP servers, wherever the node works — else the cwd's.
        let config = try Self.config(creation.callerConfig, cwd: cwd, ownMcpServers: mcpServers != nil)
        // The caller's `--auth-policy`, as acpx's runner makes its client with the flow's.
        let authPolicy = creation.authPolicy ?? config.authPolicy
        // The servers the creating agent is given: the caller's own for it, else its config's.
        // Only the config's ones sent are read, so a caller supplying its own set is not refused
        // over an unrelated bad entry in the cwd's config.
        let servers = try mcpServers.map { try $0.map { try $0.protocolSpec() } } ?? config.mcpServerSpecs()
        let launch = config.agentLaunch(for: agentCommand)
        let (command, argv) = agentArgv.map { (agentCommand, Optional($0)) } ?? (launch.command, launch.argv)
        let options = SessionAcpxState.SessionOptions(turnModel: promptOptions?.model, promptOptions)
        let meta = SessionMeta.build(options: options, agentCommand: command)
        // Under `--verbose`, what the agent writes to stderr goes to the caller as the session
        // is made, as acpx's client shows it in the flow's process; a held agent's then waits
        // for its first turn.
        let stderr = creation.verbose ? AgentStderrRelay() : nil
        // The creating agent's terminals are capped as the caller's (#219 review).
        let ceiling = TerminalOutputLimit.Source.given(try Self.terminalOutputCeiling(creation.terminalOutputCeiling))
        guard holdAgent else {
            let record = try await relayingStderr(stderr, logger: "newSession") {
                try await SessionEngine.createSession(
                    agentCommand: command, agentArgv: argv, cwd: cwd,
                    name: nonBlank(name), permission: .approveAll, authCredentials: config.auth,
                    authPolicy: authPolicy, mcpServers: servers, meta: meta, sessionOptions: options,
                    capabilities: .acpx(fs: fs),
                    handlers: handlers, baseEnvironment: creation.environment, terminalOutputCeiling: ceiling,
                    inheritStderr: inheritAgentStderr, onStderr: stderr?.observer, onLog: stderr?.logObserver)
            }
            return record.acpxRecordId
        }
        guard !stopping else { throw DaemonError.stopping }
        // Under way, a call-off of this creation is kept until it is over, however long the
        // agent takes to open the session (#219 review).
        let token = creation.creationToken
        if let token { creatingTokens.insert(token) }
        defer { if let token { creatingTokens.remove(token) } }
        let held = try await relayingStderr(stderr, logger: "newSession") {
            try await SessionEngine.createSessionHoldingAgent(
                agentCommand: command, agentArgv: argv, cwd: cwd,
                name: nonBlank(name), permission: .approveAll, authCredentials: config.auth,
                authPolicy: authPolicy, mcpServers: servers, meta: meta, sessionOptions: options,
                capabilities: .acpx(fs: fs), writesRecord: false, handlers: handlers,
                baseEnvironment: creation.environment, terminalOutputCeiling: ceiling,
                inheritStderr: inheritAgentStderr, onStderr: stderr?.observer, onLog: stderr?.logObserver)
        }
        let configuration = AgentConfiguration(mcpServers: servers, auth: config.auth)
        return try await keepMadeSession(held, stderr: stderr, token: token, configuration: configuration)
    }

    /// ``newSession(agentCommand:agentArgv:cwd:name:mcpServers:sessionOptions:creation:)`` with
    /// its agent kept or not, and offered the filesystem or not; its requests approved.
    func newSession(
        agentCommand: String, agentArgv: [String]? = nil, cwd: String, name: String? = nil,
        mcpServers: [McpServerConfig]? = nil, sessionOptions: PromptSessionOptions? = nil,
        holdAgent: Bool = false, fs: Bool? = nil
    ) async throws -> String {
        try await newSession(
            agentCommand: agentCommand, agentArgv: agentArgv, cwd: cwd, name: name, mcpServers: mcpServers,
            sessionOptions: sessionOptions, creation: SessionCreationMode(holdAgent: holdAgent, fs: fs))
    }

    // MARK: - Mutation tools

    /// A call's cap on terminal output: the caller's — bytes, `0` for none — else the
    /// daemon's own `ACPX_TERMINAL_MAX_OUTPUT_BYTES`. A bad one is refused before the
    /// call waits for the session.
    static func terminalOutputCeiling(_ requested: Int?) throws -> Int? {
        guard let requested else { return try TerminalOutputLimit.ceiling() }
        return try TerminalOutputLimit.ceiling(bytes: requested)
    }

    /// Set a session's mode on the live agent (reconnecting if needed) and persist
    /// it as the desired mode — mirrors the CLI's `set-mode`.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - modeId: the agent mode to switch to (e.g. `auto`, `read-only`).
    ///   - nonInteractivePermissions: `deny` (the default) or `fail`: what a request
    ///     needing confirmation meanwhile does.
    ///   - terminalOutputCeiling: the caller's cap on terminal output, `0` for none;
    ///     omitted, the daemon's own.
    ///   - timeoutMs: the caller's `--timeout`, in milliseconds (see
    ///     ``withSessionTurn(_:replacing:nonInteractivePermissions:terminalOutputCeiling:timeoutMs:environment:_:)``).
    ///   - environment: the caller's environment, for an agent the control starts (see there).
    ///   - verbose: whether that agent's stderr and acpx's own lines go to the caller (see there).
    ///   - client: what that agent is offered and how it signs in (see there).
    func setMode(
        sessionId: String, modeId: String, nonInteractivePermissions: String? = nil,
        terminalOutputCeiling: Int? = nil, timeoutMs: Int? = nil, environment: [String: String]? = nil,
        verbose: Bool = false, client: ClientOptions = ClientOptions()
    ) async throws -> SessionControlResult {
        let step = ControlStep<Void, Void>(
            request: { entry, _, timeout in
                let session = entry.session
                try await withTimeout(milliseconds: timeout) {
                    try await SessionControlError.wrapping("session/set_mode", context: "for mode \"\(modeId)\"") {
                        try await session.setMode(modeId)
                    }
                }
            },
            apply: { _, record in
                // Only the mode to put back, as acpx's `setDesiredModeId`: the current mode
                // is what the agent's `current_mode_update` of a turn says.
                var acpx = record.acpx ?? SessionAcpxState()
                acpx.desiredModeId = modeId
                record.acpx = acpx
            })
        let outcome = try await runControl(
            sessionId, replacing: .mode, nonInteractivePermissions: nonInteractivePermissions,
            terminalOutputCeiling: terminalOutputCeiling, timeoutMs: timeoutMs, environment: environment,
            verbose: verbose, client: client, step)
        return SessionControlResult(
            resumed: outcome.resumed, ownerPid: Self.pid(ifOwned: outcome.owned), loadError: outcome.loadError)
    }

    /// Set a session config option on the live agent (reconnecting if needed) and
    /// record it as acpx's `applyConfigOptionSelection` does — mirrors the CLI's
    /// `set <key> <value>`. The model's own option pins the model, so a reconnect puts
    /// back this one rather than what the session was created with.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - configId: the config option key the agent advertised.
    ///   - value: the value to set for that option.
    ///   - nonInteractivePermissions: `deny` (the default) or `fail`: what a request
    ///     needing confirmation meanwhile does.
    ///   - terminalOutputCeiling: the caller's cap on terminal output, `0` for none;
    ///     omitted, the daemon's own.
    ///   - timeoutMs: the caller's `--timeout`, in milliseconds (see
    ///     ``withSessionTurn(_:replacing:nonInteractivePermissions:terminalOutputCeiling:timeoutMs:environment:_:)``).
    ///   - environment: the caller's environment, for an agent the control starts (see there).
    ///   - verbose: whether that agent's stderr and acpx's own lines go to the caller (see there).
    ///   - client: what that agent is offered and how it signs in (see there).
    /// - Returns: the agent's advertised config options after the change (the data
    ///   the CLI echoes; may be empty if the agent reports none), and whether the
    ///   session had to be taken back first.
    func setConfigOption(
        sessionId: String, configId: String, value: String, nonInteractivePermissions: String? = nil,
        terminalOutputCeiling: Int? = nil, timeoutMs: Int? = nil, environment: [String: String]? = nil,
        verbose: Bool = false, client: ClientOptions = ClientOptions()
    ) async throws -> SessionControlResult {
        let step = ControlStep(
            request: { entry, record, timeout in
                // acpx's owner control: a value for the model's own option is a model id,
                // checked and resolved against the session's advertised models.
                let (connection, id) = (entry.agent.connection, entry.session.id)
                let models = ModelSupport.advertisedModelState(record.acpx ?? SessionAcpxState())
                let agentCommand = record.agentCommand
                return try await withTimeout(milliseconds: timeout) {
                    try await ModelApplication.setConfigOption(
                        connection: connection, sessionId: id, configId: configId, value: value, models: models,
                        agentCommand: agentCommand)
                }
            },
            apply: { (response: SetSessionConfigOptionResponse, record: inout SessionRecord) in
                var acpx = record.acpx ?? SessionAcpxState()
                ModelSupport.applyConfigOptionSelection(configId, value: value, response: response, to: &acpx)
                record.acpx = acpx
                // As the agent reported them: none, for a reply that only acknowledges.
                return response.rawConfigOptions
            })
        let outcome = try await runControl(
            sessionId, replacing: .configOption(configId), nonInteractivePermissions: nonInteractivePermissions,
            terminalOutputCeiling: terminalOutputCeiling, timeoutMs: timeoutMs, environment: environment,
            verbose: verbose, client: client, step)
        return SessionControlResult(
            resumed: outcome.resumed, rawConfigOptions: outcome.value, ownerPid: Self.pid(ifOwned: outcome.owned),
            loadError: outcome.loadError)
    }

    /// Set a session's model on the live agent (reconnecting if needed) through the
    /// control the session advertises, as acpx's `setSessionModel` does — refused when
    /// it advertises none — and record it as `applyModelSelection` does: pinned and
    /// current. Mirrors the CLI's `set model <value>` for legacy-control agents.
    ///
    /// - Parameters:
    ///   - sessionId: the acpx record id or the ACP session id.
    ///   - modelId: the model id to switch to.
    ///   - nonInteractivePermissions: `deny` (the default) or `fail`: what a request
    ///     needing confirmation meanwhile does.
    ///   - terminalOutputCeiling: the caller's cap on terminal output, `0` for none;
    ///     omitted, the daemon's own.
    ///   - timeoutMs: the caller's `--timeout`, in milliseconds (see
    ///     ``withSessionTurn(_:replacing:nonInteractivePermissions:terminalOutputCeiling:timeoutMs:environment:_:)``).
    ///   - environment: the caller's environment, for an agent the control starts (see there).
    ///   - verbose: whether that agent's stderr and acpx's own lines go to the caller (see there).
    ///   - client: what that agent is offered and how it signs in (see there).
    func setModel(
        sessionId: String, modelId: String, nonInteractivePermissions: String? = nil,
        terminalOutputCeiling: Int? = nil, timeoutMs: Int? = nil, environment: [String: String]? = nil,
        verbose: Bool = false, client: ClientOptions = ClientOptions()
    ) async throws -> SessionControlResult {
        let step = ControlStep(
            request: { entry, record, timeout in
                let (connection, id) = (entry.agent.connection, entry.session.id)
                let models = ModelSupport.advertisedModelState(record.acpx ?? SessionAcpxState())
                let agentCommand = record.agentCommand
                return try await withTimeout(milliseconds: timeout) {
                    try await ModelApplication.setModel(
                        connection: connection, sessionId: id, modelId: modelId, models: models,
                        agentCommand: agentCommand)
                }
            },
            apply: { (response: SetSessionConfigOptionResponse?, record: inout SessionRecord) in
                var acpx = record.acpx ?? SessionAcpxState()
                ModelSupport.applyModelSelection(modelId, response: response, to: &acpx)
                record.acpx = acpx
            })
        let outcome = try await runControl(
            sessionId, replacing: .configOption("model"), nonInteractivePermissions: nonInteractivePermissions,
            terminalOutputCeiling: terminalOutputCeiling, timeoutMs: timeoutMs, environment: environment,
            verbose: verbose, client: client, step)
        return SessionControlResult(
            resumed: outcome.resumed, ownerPid: Self.pid(ifOwned: outcome.owned), loadError: outcome.loadError)
    }

    /// Whether this daemon holds a session live, and its agent's process while it runs:
    /// the health of acpx's queue owner, which the prompt banner and `status` report. A
    /// session is held while its owner holds it (``SessionOwner``) — its agent can be gone
    /// meanwhile, closed after a prompt timed out or exited on its own, as acpx's owner
    /// outlives its client's agent — and otherwise while its agent runs. An entry whose
    /// agent has exited, or whose connection has closed, is only kept until the next turn
    /// replaces it.
    func sessionStatus(sessionId: String) async -> LiveSessionStatus {
        guard let record = findRecord(sessionId) else { return LiveSessionStatus(live: false) }
        let owned = owners[record.acpxRecordId] != nil
        guard let entry = live[record.acpxRecordId] else { return LiveSessionStatus(live: owned) }
        let lifecycle = entry.agent.lifecycle
        guard lifecycle?.running != false, await !entry.agent.connection.isClosed else {
            return LiveSessionStatus(live: owned)
        }
        return LiveSessionStatus(live: true, pid: lifecycle?.pid.map { Int($0) })
    }

    /// ``runPrompt(sessionId:text:blocks:content:wait:permissionMode:nonInteractivePermissions:streamWire:permissionPolicy:terminalOutputCeiling:sessionOptions:limits:direct:fs:authPolicy:turnToken:callerConfig:verbose:environment:)``
    /// as the tool calls it.
    func runPrompt(
        sessionId: String, text: String, blocks: [PromptBlock]?, content: [JSONValue]?, wait: Bool,
        permissionMode: String?, nonInteractivePermissions: String?, mode: PromptTurnMode,
        permissionPolicy: PermissionRules?, terminalOutputCeiling: Int?, sessionOptions: PromptSessionOptions?,
        limits: PromptLimits?
    ) async throws -> String {
        try await runPrompt(
            sessionId: sessionId, text: text, blocks: blocks, content: content, wait: wait,
            permissionMode: permissionMode, nonInteractivePermissions: nonInteractivePermissions,
            streamWire: mode.streamWire, permissionPolicy: permissionPolicy,
            terminalOutputCeiling: terminalOutputCeiling, sessionOptions: sessionOptions, limits: limits,
            direct: mode.direct, fs: mode.fs, terminal: mode.terminal, authPolicy: mode.authPolicy,
            turnToken: mode.turnToken,
            callerConfig: mode.callerConfig, verbose: mode.verbose, environment: mode.environment,
            requestId: mode.requestId)
    }

    /// Drop a live session — by its acpx record id — and terminate its agent (so the
    /// next call relaunches).
    func evict(_ recordId: String) async {
        guard let entry = live.removeValue(forKey: recordId) else { return }
        // A creation's token keeps its agent no longer: nothing is left for a call-off.
        madeCreations = madeCreations.filter { $0.value.agent !== entry.agent }
        try? await entry.agent.close()
    }

}
