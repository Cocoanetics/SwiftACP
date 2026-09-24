import Foundation
import JSONFoundation
import JSONRPCWire

extension Implementation {
    /// The default identity this library presents to agents.
    public static let acpx = Implementation(name: "acpx-swift", version: ACPVersion.current)
}

extension ClientCapabilities {
    /// A headless controller: real file access, but the agent runs its own
    /// terminals (we don't advertise client-side terminals). See ``acpx`` for what the
    /// acpx CLI advertises.
    public static let headlessController = ClientCapabilities(
        fs: FileSystemCapability(readTextFile: true, writeTextFile: true), terminal: false)

    /// What acpx advertises: real file access, and client-side terminals — where
    /// ``TerminalManager`` can run them (macOS and Linux). ``ACPAgent/launch(agent:argv:cwd:handlers:clientInfo:capabilities:environment:authCredentials:authPolicy:inheritStderr:overrides:terminalOutputCeiling:onClientRequest:onRawWire:)``
    /// gives a connection advertising terminals a ``TerminalManager`` to run them on.
    public static let acpx = ClientCapabilities(
        fs: FileSystemCapability(readTextFile: true, writeTextFile: true), terminal: terminalsSupported)

    #if os(macOS) || os(Linux)
    static let terminalsSupported = true
    #else
    static let terminalsSupported = false
    #endif
}

// `ACPAgent`/`ACPSession` spawn an agent adapter and speak to it over the
// swift-subprocess child stdio transport (`JSONRPCSubprocess.StdioTransport`),
// which exists only on macOS/Linux/Windows. iOS/Android apps can't spawn child
// processes; they reach a remote `acpxd` over MCP instead. So the whole spawn-client
// section below — and its `JSONRPCSubprocess` import — is gated off iOS/Android. The
// transport-agnostic `ACPAgentConnection` and every protocol value type stay available
// on all platforms.
#if os(macOS) || os(Linux) || os(Windows)
import JSONRPCSubprocess

/// A launched, initialized ACP agent — ready to create sessions.
///
/// ```swift
/// let agent = try await ACPAgent.launch(agent: "claude", cwd: repo,
///                                        permission: .approveReads)
/// let session = try await agent.newSession()
/// Task { for await update in await session.updates() { render(update) } }
/// let outcome = try await session.run("Explain this project")
/// print(outcome.text, outcome.stopReason)
/// await agent.close()
/// ```
public final class ACPAgent: Sendable {
    public let name: String
    public let cwd: String
    public let connection: ACPAgentConnection
    /// The agent subprocess transport: one newline-terminated JSON line per message
    /// (ACP framing), with every line shown to ``rawWire`` on its way through. On macOS
    /// and Linux the agent is started and read as acpx's client does, so its end is
    /// known (``lifecycle``); elsewhere JSONFoundation's swift-subprocess transport runs
    /// it.
    public let transport: any JSONRPCMessageTransport
    /// Every message body exchanged with the agent, as raw bytes in both directions —
    /// from the `initialize` handshake on when `launch` was given `onRawWire`.
    /// Re-point it with ``RawWireTap/set(_:)``.
    public let rawWire: RawWireTap
    /// The agent's `initialize` response (capabilities, auth methods, info).
    public let initializeResult: InitializeResponse
    /// The terminal manager `launch` gave the connection, when it advertises terminals.
    let terminals: (any ACPTerminalHandler)?

    public var agentCapabilities: AgentCapabilities? { initializeResult.agentCapabilities }
    /// Which non-text prompt content the agent accepts, as it advertised on
    /// `initialize`. `nil` (or an unset flag) means "not advertised" — treat as off.
    public var promptCapabilities: PromptCapabilities? {
        initializeResult.agentCapabilities?.promptCapabilities
    }
    public var authMethods: [AuthMethod] { initializeResult.authMethods ?? [] }

    init(
        name: String, cwd: String, connection: ACPAgentConnection,
        transport: any JSONRPCMessageTransport, rawWire: RawWireTap,
        initializeResult: InitializeResponse, terminals: (any ACPTerminalHandler)? = nil
    ) {
        self.name = name
        self.cwd = cwd
        self.connection = connection
        self.transport = transport
        self.rawWire = rawWire
        self.initializeResult = initializeResult
        self.terminals = terminals
    }

    /// Caps the output of the terminals the agent creates from now on, `nil` being no
    /// cap — see ``TerminalManager/setOutputCeiling(_:)``. `launch` caps them by this
    /// process's `ACPX_TERMINAL_MAX_OUTPUT_BYTES`; a host running turns for other
    /// processes sets each caller's own. Nothing changes without a terminal manager.
    public func setTerminalOutputCeiling(_ ceiling: Int?) async {
        #if os(macOS) || os(Linux)
        guard let manager = terminals as? TerminalManager else { return }
        await manager.setOutputCeiling(ceiling)
        #endif
    }

    /// Spawn an agent's ACP adapter, run the `initialize` handshake, and return
    /// a ready agent. Throws if the adapter can't launch or the handshake fails.
    public static func launch(
        agent name: String,
        argv: [String]? = nil,
        cwd: String = FileManager.default.currentDirectoryPath,
        handlers: ACPClientHandlers,
        clientInfo: Implementation = .acpx,
        capabilities: ClientCapabilities = .headlessController,
        environment: [String: String]? = nil,
        authCredentials: [String: String] = [:],
        authPolicy: String = "skip",
        inheritStderr: Bool = true,
        overrides: [String: String] = [:],
        terminalOutputCeiling: TerminalOutputLimit.Source = .environment,
        onClientRequest: (@Sendable (String) -> Void)? = nil,
        onRawWire: RawWireTap.Observer? = nil
    ) async throws -> ACPAgent {
        // Build the agent's environment exactly like acpx: inherit the parent
        // environment, promote `ACPX_AUTH_*`, and inject configured `auth`
        // credentials. An explicit `environment` is used as-is.
        let effectiveEnvironment =
            environment ?? AgentEnvironment.forAgent(authCredentials: authCredentials)
        // acpx builds its terminal manager with its client, before the agent starts —
        // so a bad `ACPX_TERMINAL_MAX_OUTPUT_BYTES` fails the launch outright, and a
        // command the agent starts while it answers `initialize` is capped already.
        let terminals = try terminalManager(for: capabilities, cwd: cwd, ceiling: terminalOutputCeiling)
        // Read when the client starts, before anything else: a bad value is refused.
        let maxMessageBytes = try AcpMessageLimit.bytes()
        let spec = try AgentRegistry.launch(
            for: name, argv: argv, cwd: cwd, environment: effectiveEnvironment,
            inheritStderr: inheritStderr, overrides: overrides)
        let agentCommand = failureName(agent: name, argv: argv, overrides: overrides)
        // A launch path that does not exist is acpx's `AGENT_SPAWN_ENOENT`; established
        // here so the failure names the command instead of surfacing as an opaque
        // subprocess error once the handshake times out.
        if let failure = AgentLaunchPreflight.failure(for: spec, agentCommand: agentCommand) {
            throw failure
        }
        // Tapped from the start, so an observer given here sees the handshake too.
        let rawWire = RawWireTap(onRawWire)
        let transport = try startTransport(
            spec, agentCommand: agentCommand, maxMessageBytes: maxMessageBytes, tap: rawWire)
        let connection = ACPAgentConnection(transport: transport, handlers: handlers)
        if let terminals { await connection.setTerminalHandler(terminals) }
        await connection.start()
        // Set the observer before `initialize` so the handshake requests are seen.
        if let onClientRequest { await connection.setClientRequestObserver(onClientRequest) }
        do {
            let info = try await connection.initialize(
                capabilities: capabilities, clientInfo: clientInfo)
            try await authenticateIfRequired(
                connection: connection, methods: info.authMethods ?? [],
                authCredentials: authCredentials, authPolicy: authPolicy)
            #if os(macOS) || os(Linux)
            (transport as? AgentProcessTransport)?.captureDescendants()
            #endif
            return ACPAgent(
                name: name, cwd: cwd, connection: connection,
                transport: transport, rawWire: rawWire, initializeResult: info, terminals: terminals)
        } catch {
            // A command the agent started meanwhile goes with it: nothing else would
            // ever reach its terminal.
            await connection.shutDownTerminals()
            #if os(macOS) || os(Linux)
            if let agent = transport as? AgentProcessTransport {
                // Whether the agent went is settled before anything closes it: closing ends
                // its stdin, and it would exit then, whatever the failure was.
                let failure = await startupFailure(error, of: agent, agentCommand: agentCommand)
                agent.close()
                await connection.close()
                await agent.terminate()
                throw failure
            }
            #endif
            await connection.close()
            transport.close()
            throw error
        }
    }

    /// The agent's transport: started and read as acpx's client does on macOS and
    /// Linux; JSONFoundation's swift-subprocess transport elsewhere.
    private static func startTransport(
        _ spec: ProcessLaunch, agentCommand: String, maxMessageBytes: Int?, tap: RawWireTap
    ) throws -> any JSONRPCMessageTransport {
        #if os(macOS) || os(Linux)
        do {
            return try AgentProcessTransport.start(
                spec, agentCommand: agentCommand, maxMessageBytes: maxMessageBytes, tap: tap)
        } catch let error as ChildProcess.SpawnError {
            // acpx's `AgentSpawnError`, qualified when a launch path is missing.
            throw AgentLaunchError(
                agentCommand: agentCommand, workingDirectory: spec.workingDirectory,
                detailCode: error.code == ENOENT ? AgentLaunchError.spawnENOENT : nil)
        }
        #else
        let framing = TappedFraming(LineFraming(), tap: tap)
        guard let maxMessageBytes else { return StdioTransport(endpoint: .childProcess(spec), framing: framing) }
        let limit = MessageLimit.Signal()
        let limited = MessageLimit.Framing(framing, limit: maxMessageBytes, signal: limit)
        return MessageLimit.Transport(StdioTransport(endpoint: .childProcess(spec), framing: limited), signal: limit)
        #endif
    }

    #if os(macOS) || os(Linux)
    /// acpx's `normalizeInitializeError`: a handshake that failed because the agent went
    /// — its connection closed, or it has exited within 100 ms — is
    /// ``AgentStartupError``, with its exit and the end of its stderr. A line too long
    /// stays itself, and so does anything else the agent answered.
    private static func startupFailure(
        _ error: Error, of transport: AgentProcessTransport, agentCommand: String
    ) async -> Error {
        guard !(error is AcpMessageLimitError) else { return error }
        let closed = ACPAgentConnection.isConnectionClosed(error)
        let exited = await transport.waitForExit(timeout: .milliseconds(100))
        guard closed || exited else { return error }
        let exit = transport.lifecycle.lastExit
        return AgentStartupError(
            agentCommand: agentCommand, exitCode: exit?.exitCode, signal: exit?.signal,
            stderrSummary: transport.stderrSummary)
    }
    #endif

    /// The terminal manager a connection advertising `capabilities` runs the agent's
    /// commands on: one per connection, capped by acpx's host ceiling, running commands
    /// in `cwd` unless a session or the request says otherwise.
    ///
    /// The ceiling is read whether or not terminals are advertised: acpx builds its
    /// terminal manager with every client, so `--no-terminal` does not excuse a bad one.
    private static func terminalManager(
        for capabilities: ClientCapabilities, cwd: String, ceiling source: TerminalOutputLimit.Source
    ) throws -> (any ACPTerminalHandler)? {
        let ceiling: Int?
        switch source {
        case .environment: ceiling = try TerminalOutputLimit.ceiling()
        case .given(let bytes): ceiling = bytes
        }
        #if os(macOS) || os(Linux)
        guard capabilities.terminal else { return nil }
        return TerminalManager(cwd: cwd, outputCeiling: ceiling)
        #else
        _ = ceiling
        return nil
        #endif
    }

    /// The command a launch failure names — acpx's `options.agentCommand`. Given an
    /// argv, that is the caller's own command, since an expansion of the name was never
    /// launched; otherwise it is what the name expands to.
    static func failureName(agent name: String, argv: [String]?, overrides: [String: String]) -> String {
        guard argv == nil else { return name }
        return AgentRegistry.command(for: name, overrides: overrides) ?? name
    }

    /// Convenience that builds standard handlers from a permission policy. Writes
    /// the agent asks for are gated by it too — see ``WriteApproval`` — with
    /// `nonInteractivePermissions` deciding what a write needing confirmation does
    /// when there is no terminal to ask on.
    public static func launch(
        agent name: String,
        argv: [String]? = nil,
        cwd: String = FileManager.default.currentDirectoryPath,
        permission: PermissionPolicy,
        nonInteractivePermissions: NonInteractivePermissionPolicy = .deny,
        permissionRules: PermissionRules? = nil,
        clientInfo: Implementation = .acpx,
        capabilities: ClientCapabilities = .headlessController,
        environment: [String: String]? = nil,
        authCredentials: [String: String] = [:],
        authPolicy: String = "skip",
        inheritStderr: Bool = true,
        overrides: [String: String] = [:],
        terminalOutputCeiling: TerminalOutputLimit.Source = .environment,
        onClientRequest: (@Sendable (String) -> Void)? = nil,
        onRawWire: RawWireTap.Observer? = nil
    ) async throws -> ACPAgent {
        try await launch(
            agent: name, argv: argv, cwd: cwd,
            handlers: .standard(
                permission: permission, nonInteractivePermissions: nonInteractivePermissions,
                rules: permissionRules),
            clientInfo: clientInfo, capabilities: capabilities, environment: environment,
            authCredentials: authCredentials, authPolicy: authPolicy,
            inheritStderr: inheritStderr, overrides: overrides, terminalOutputCeiling: terminalOutputCeiling,
            onClientRequest: onClientRequest, onRawWire: onRawWire)
    }

    /// Authenticate using one of the agent's advertised auth methods.
    public func authenticate(methodId: String) async throws {
        try await connection.authenticate(methodId: methodId)
    }

    /// After `initialize`, if the agent advertised auth methods, select a
    /// credential (this process's `ACPX_AUTH_*` env first, then configured
    /// `auth`) and call ACP `authenticate`. When none match: throw under the
    /// `fail` policy, else proceed (the agent may authenticate itself). Faithful
    /// to acpx's `authenticateIfRequired`/`selectAuthMethod`.
    private static func authenticateIfRequired(
        connection: ACPAgentConnection,
        methods: [AuthMethod],
        authCredentials: [String: String],
        authPolicy: String
    ) async throws {
        guard !methods.isEmpty else { return }
        for method in methods {
            let hasEnv = AgentEnvironment.readEnvCredential(methodId: method.id) != nil
            let configCredential = AgentEnvironment.resolveConfiguredAuthCredential(
                methodId: method.id, authCredentials: authCredentials)
            let hasConfig =
                configCredential?.trimmingCharacters(in: .whitespaces).isEmpty == false
            if hasEnv || hasConfig {
                try await connection.authenticate(methodId: method.id)
                return
            }
        }
        if authPolicy == "fail" {
            throw AuthPolicyError(methodIds: methods.map(\.id))
        }
    }

    /// Create a new session rooted at `cwd` (defaults to the agent's cwd).
    public func newSession(
        cwd: String? = nil,
        mcpServers: [MCPServerSpec] = [],
        additionalDirectories: [String]? = nil,
        meta: JSONValue? = nil
    ) async throws -> ACPSession {
        let response = try await connection.newSession(
            NewSessionRequest(
                cwd: cwd ?? self.cwd, mcpServers: mcpServers,
                additionalDirectories: additionalDirectories, meta: meta))
        return ACPSession(
            id: response.sessionId, agent: self, modes: response.modes, meta: response.meta,
            configOptions: response.configOptions, models: response.models)
    }

    /// Resume a previously created session by id (requires `loadSession` support).
    ///
    /// The agent replays the session's history as `session/update`s, and may go on
    /// after it answers, so this returns once they have stopped for a moment — acpx's
    /// `loadSessionWithOptions` waits the same way (80 ms without one, at most 5 s;
    /// longer fails the load).
    ///
    /// - Parameter suppressReplayUpdates: neither deliver nor show (``rawWire``) this
    ///   session's `session/update`s that arrive meanwhile: the caller already has that
    ///   history. acpx does this when it reconnects a session for a turn or a control.
    public func loadSession(
        id: SessionId,
        cwd: String? = nil,
        mcpServers: [MCPServerSpec] = [],
        additionalDirectories: [String]? = nil,
        meta: JSONValue? = nil,
        suppressReplayUpdates: Bool = false
    ) async throws -> ACPSession {
        let response = try await connection.loadSession(
            LoadSessionRequest(
                sessionId: id, cwd: cwd ?? self.cwd, mcpServers: mcpServers,
                additionalDirectories: additionalDirectories, meta: meta),
            suppressReplayUpdates: suppressReplayUpdates, rawWire: rawWire)
        return ACPSession(
            id: id, agent: self, modes: response.modes, meta: response.meta,
            configOptions: response.configOptions, models: response.models)
    }

    /// Resume a previously created session (`session/resume`).
    public func resumeSession(
        id: SessionId, cwd: String? = nil, mcpServers: [MCPServerSpec] = [],
        additionalDirectories: [String]? = nil, meta: JSONValue? = nil
    ) async throws -> ACPSession {
        let response = try await connection.resumeSession(
            ResumeSessionRequest(
                sessionId: id, cwd: cwd ?? self.cwd, mcpServers: mcpServers,
                additionalDirectories: additionalDirectories, meta: meta))
        return ACPSession(
            id: id, agent: self, modes: response.modes, meta: response.meta,
            configOptions: response.configOptions, models: response.models)
    }

    /// Reconnect to an existing session the way the agent says it can be reconnected:
    /// `session/resume` when it advertises that (as Codex does), else `session/load`
    /// when it advertises `loadSession`.
    ///
    /// Throws ``SessionReconnectUnsupported`` when it advertises neither, without
    /// sending anything: a client should not call a method the agent said it lacks,
    /// and one that does not answer unknown methods would hang the caller. acpx makes
    /// the same decision (`supportsResumeSession` / `supportsLoadSession`) and then
    /// starts a new session instead.
    ///
    /// - Parameter suppressReplayUpdates: passed to ``loadSession(id:cwd:mcpServers:additionalDirectories:meta:suppressReplayUpdates:)``;
    ///   `session/resume` replays nothing.
    public func reconnectSession(
        id: SessionId, cwd: String? = nil, mcpServers: [MCPServerSpec] = [],
        additionalDirectories: [String]? = nil, meta: JSONValue? = nil,
        suppressReplayUpdates: Bool = false
    ) async throws -> ACPSession {
        if agentCapabilities?.sessionCapabilities?.supportsResume == true {
            return try await resumeSession(
                id: id, cwd: cwd, mcpServers: mcpServers,
                additionalDirectories: additionalDirectories, meta: meta)
        }
        guard agentCapabilities?.loadSession == true else {
            throw SessionReconnectUnsupported()
        }
        return try await loadSession(
            id: id, cwd: cwd, mcpServers: mcpServers,
            additionalDirectories: additionalDirectories, meta: meta,
            suppressReplayUpdates: suppressReplayUpdates)
    }

    /// Gracefully shut down the connection and terminate the subprocess — after the
    /// commands the agent still runs through the client, as acpx retires its
    /// terminals before the agent.
    public func close() async {
        await connection.shutDownTerminals()
        #if os(macOS) || os(Linux)
        if let agent = transport as? AgentProcessTransport {
            // The transport is closed here and now, so closing the connection is what
            // the agent's end is put down to — as acpx records it — before the stdin that
            // closing ends lets the agent exit first: the connection's own close reaches
            // the transport from a task of its own.
            agent.close()
            await connection.close()
            await agent.terminate()
            return
        }
        #endif
        await connection.close()
        transport.close()
    }

    /// The agent's process as acpx reports it (`getAgentLifecycleSnapshot`): its pid,
    /// when it started, whether it runs, and how it ended — what the session record
    /// keeps of it. `nil` where it cannot be watched (Windows).
    public var lifecycle: AgentLifecycleSnapshot? {
        #if os(macOS) || os(Linux)
        return (transport as? AgentProcessTransport)?.lifecycle
        #else
        return nil
        #endif
    }
}

#endif

/// The agent advertises neither `session/resume` nor `session/load`, so it cannot take
/// back a session it created earlier — the caller starts a new one, or refuses to.
public struct SessionReconnectUnsupported: LocalizedError, Equatable, Sendable {
    public init() {}

    /// acpx's reason for the same case.
    public var errorDescription: String? { "agent does not support session/resume or session/load" }
}
