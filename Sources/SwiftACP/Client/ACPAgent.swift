import Foundation
import JSONFoundation
import JSONRPCStdio
import JSONRPCWire

extension Implementation {
    /// The default identity this library presents to agents.
    public static let acpx = Implementation(name: "acpx-swift", version: ACPVersion.current)
}

extension ClientCapabilities {
    /// A headless controller: real file access, but the agent runs its own
    /// terminals (we don't advertise client-side terminals).
    public static let headlessController = ClientCapabilities(
        fs: FileSystemCapability(readTextFile: true, writeTextFile: true), terminal: false)
}

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
    /// The agent subprocess transport: JSONFoundation's zero-dep
    /// `Foundation.Process` stdio transport, framed as one newline-terminated JSON
    /// line per message (ACP framing).
    public let transport: ProcessTransport<LineFraming>
    /// The agent's `initialize` response (capabilities, auth methods, info).
    public let initializeResult: InitializeResponse

    public var agentCapabilities: AgentCapabilities? { initializeResult.agentCapabilities }
    public var authMethods: [AuthMethod] { initializeResult.authMethods ?? [] }

    init(
        name: String, cwd: String, connection: ACPAgentConnection,
        transport: ProcessTransport<LineFraming>, initializeResult: InitializeResponse
    ) {
        self.name = name
        self.cwd = cwd
        self.connection = connection
        self.transport = transport
        self.initializeResult = initializeResult
    }

    /// Spawn an agent's ACP adapter, run the `initialize` handshake, and return
    /// a ready agent. Throws if the adapter can't launch or the handshake fails.
    public static func launch(
        agent name: String,
        cwd: String = FileManager.default.currentDirectoryPath,
        handlers: ACPClientHandlers,
        clientInfo: Implementation = .acpx,
        capabilities: ClientCapabilities = .headlessController,
        environment: [String: String]? = nil,
        authCredentials: [String: String] = [:],
        authPolicy: String = "skip",
        inheritStderr: Bool = true,
        overrides: [String: String] = [:],
        onClientRequest: (@Sendable (String) -> Void)? = nil
    ) async throws -> ACPAgent {
        // Build the agent's environment exactly like acpx: inherit the parent
        // environment, promote `ACPX_AUTH_*`, and inject configured `auth`
        // credentials. An explicit `environment` is used as-is.
        let effectiveEnvironment =
            environment ?? AgentEnvironment.forAgent(authCredentials: authCredentials)
        let spec = AgentRegistry.launch(
            for: name, cwd: cwd, environment: effectiveEnvironment,
            inheritStderr: inheritStderr, overrides: overrides)
        let transport = try ProcessTransport(launch: spec, framing: LineFraming())
        let connection = ACPAgentConnection(transport: transport, handlers: handlers)
        await connection.start()
        // Set the observer before `initialize` so the handshake requests are seen.
        if let onClientRequest { await connection.setClientRequestObserver(onClientRequest) }
        do {
            let info = try await connection.initialize(
                capabilities: capabilities, clientInfo: clientInfo)
            try await authenticateIfRequired(
                connection: connection, methods: info.authMethods ?? [],
                authCredentials: authCredentials, authPolicy: authPolicy)
            return ACPAgent(
                name: name, cwd: cwd, connection: connection,
                transport: transport, initializeResult: info)
        } catch {
            transport.close()
            throw error
        }
    }

    /// Convenience that builds standard handlers from a permission policy.
    public static func launch(
        agent name: String,
        cwd: String = FileManager.default.currentDirectoryPath,
        permission: PermissionPolicy,
        clientInfo: Implementation = .acpx,
        environment: [String: String]? = nil,
        authCredentials: [String: String] = [:],
        authPolicy: String = "skip",
        inheritStderr: Bool = true,
        overrides: [String: String] = [:],
        onClientRequest: (@Sendable (String) -> Void)? = nil
    ) async throws -> ACPAgent {
        try await launch(
            agent: name, cwd: cwd, handlers: .standard(permission: permission),
            clientInfo: clientInfo, environment: environment,
            authCredentials: authCredentials, authPolicy: authPolicy,
            inheritStderr: inheritStderr, overrides: overrides, onClientRequest: onClientRequest)
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
        return ACPSession(id: response.sessionId, agent: self, modes: response.modes)
    }

    /// Resume a previously created session by id (requires `loadSession` support).
    public func loadSession(
        id: SessionId,
        cwd: String? = nil,
        mcpServers: [MCPServerSpec] = [],
        additionalDirectories: [String]? = nil,
        meta: JSONValue? = nil
    ) async throws -> ACPSession {
        let response = try await connection.loadSession(
            LoadSessionRequest(
                sessionId: id, cwd: cwd ?? self.cwd, mcpServers: mcpServers,
                additionalDirectories: additionalDirectories, meta: meta))
        return ACPSession(id: id, agent: self, modes: response.modes)
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
        return ACPSession(id: id, agent: self, modes: response.modes)
    }

    /// Reconnect to an existing session, preferring `session/resume` when the
    /// agent advertises it (as Codex does), else `session/load`.
    public func reconnectSession(
        id: SessionId, cwd: String? = nil, mcpServers: [MCPServerSpec] = [],
        additionalDirectories: [String]? = nil, meta: JSONValue? = nil
    ) async throws -> ACPSession {
        if agentCapabilities?.sessionCapabilities?.supportsResume == true {
            return try await resumeSession(
                id: id, cwd: cwd, mcpServers: mcpServers,
                additionalDirectories: additionalDirectories, meta: meta)
        }
        return try await loadSession(
            id: id, cwd: cwd, mcpServers: mcpServers,
            additionalDirectories: additionalDirectories, meta: meta)
    }

    /// Suspends until the agent subprocess exits.
    public func waitForExit() async -> ProcessExit {
        await transport.waitForExit()
    }

    /// Gracefully shut down the connection and terminate the subprocess.
    public func close() async {
        await connection.close()
        transport.close()
    }
}

/// A live session you can prompt. Bound to one `sessionId` on one agent.
public struct ACPSession: Sendable {
    public let id: SessionId
    public let agent: ACPAgent
    /// The mode state reported at creation (e.g. Codex's "read-only"/"auto").
    public let modes: SessionModeState?

    public init(id: SessionId, agent: ACPAgent, modes: SessionModeState? = nil) {
        self.id = id
        self.agent = agent
        self.modes = modes
    }

    /// A stream of this session's updates only. Subscribe before prompting.
    public func updates() async -> AsyncStream<SessionUpdate> {
        let all = await agent.connection.updates()
        let sessionId = id
        return AsyncStream { continuation in
            let task = Task {
                for await note in all where note.sessionId == sessionId {
                    continuation.yield(note.update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Send a prompt and await the turn's stop reason. Updates stream separately
    /// via ``updates()``.
    @discardableResult
    public func prompt(_ blocks: [ContentBlock], meta: JSONValue? = nil) async throws -> PromptResponse {
        try await agent.connection.prompt(
            PromptRequest(sessionId: id, prompt: blocks, meta: meta))
    }

    @discardableResult
    public func prompt(_ text: String, meta: JSONValue? = nil) async throws -> PromptResponse {
        try await prompt([.text(text)], meta: meta)
    }

    /// Send a prompt and collect the full turn: every streamed update is passed
    /// to `onUpdate` (in order) and the agent's text is concatenated. Returns
    /// once the turn ends. Deterministic — no updates are dropped.
    @discardableResult
    public func run(
        _ blocks: [ContentBlock],
        meta: JSONValue? = nil,
        onUpdate: (@Sendable (SessionUpdate) -> Void)? = nil
    ) async throws -> PromptOutcome {
        let (subscriptionId, stream) = await agent.connection.makeSubscription()
        let sessionId = id
        let collector = TextCollector()
        let consumer = Task {
            for await note in stream where note.sessionId == sessionId {
                if case .agentMessageChunk(let block) = note.update, let text = block.text {
                    await collector.append(text)
                }
                onUpdate?(note.update)
            }
        }
        do {
            let response = try await prompt(blocks, meta: meta)
            await agent.connection.endSubscription(subscriptionId)
            await consumer.value
            return await PromptOutcome(stopReason: response.stopReason, text: collector.text)
        } catch {
            await agent.connection.endSubscription(subscriptionId)
            consumer.cancel()
            throw error
        }
    }

    @discardableResult
    public func run(
        _ text: String,
        meta: JSONValue? = nil,
        onUpdate: (@Sendable (SessionUpdate) -> Void)? = nil
    ) async throws -> PromptOutcome {
        try await run([.text(text)], meta: meta, onUpdate: onUpdate)
    }

    /// Request cancellation of the in-flight turn.
    public func cancel() async throws {
        try await agent.connection.cancel(sessionId: id)
    }

    public func setMode(_ modeId: String) async throws {
        try await agent.connection.setMode(SetSessionModeRequest(sessionId: id, modeId: modeId))
    }
}

/// The result of ``ACPSession/run(_:meta:onUpdate:)``.
public struct PromptOutcome: Sendable {
    public var stopReason: StopReason
    /// Concatenation of all `agent_message_chunk` text for the turn.
    public var text: String
}

/// A tiny actor that accumulates streamed text without data races.
actor TextCollector {
    private(set) var text = ""
    func append(_ chunk: String) { text += chunk }
}
