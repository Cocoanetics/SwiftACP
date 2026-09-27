import ACPXCore
import ACPXFlows
import Foundation
import JSONFoundation
import SwiftACP

/// The CLI's part of a flow's ACP turns (``FlowSessionRunner``): acpx's `runOnce` with the
/// options acpx's flow runner gives it — its `connectionOptions` and `sessionOptions`. So
/// the turn has no timeout of its own and no prompt retries, advertises a terminal whatever
/// `--no-terminal` says, and sends no system prompt: acpx's flow runner passes none of
/// those on.
struct FlowAgentSessions: FlowSessionRunner {
    let flags: GlobalFlags
    let config: ResolvedAcpxConfig
    let permission: PermissionPolicy
    let permissionRules: PermissionRules?
    let mcpServers: [MCPServerSpec]
    /// Called with the agent's connection once the agent is up: lets a test hold what the
    /// connection does.
    var onConnected: (@Sendable (ACPAgentConnection) async -> Void)?
    /// The token each persistent session of the run was made under (``FlowCreations``).
    let creations = FlowCreations()

    func runIsolated(_ turn: FlowTurn) async throws -> String {
        let owner = FlowTurnOwner()
        let events = FlowTurnEvents(turn)
        let errors = FlowTurnErrors()
        let stopListening = turn.control.onStop { owner.stop() }
        defer { stopListening() }
        do {
            let sessionId = try await run(turn, owner: owner, events: events, errors: errors)
            await owner.close()
            await events.finish()
            return sessionId
        } catch {
            // acpx's client closes before its turn ends, whatever ended it; what it took in
            // until then is the turn's.
            await owner.close()
            await events.finish()
            // acpx's `directExecutionError`: the agent gone — or its launch called off — once
            // the turn was stopped, it fails with why it was stopped.
            if let reason = turn.control.stopReason, error is CancellationError { throw reason }
            throw turn.control.turnError(error)
        }
    }

    /// acpx's `runOnce`: the agent started, a session created with the invocation's model,
    /// and the prompt sent — the attempt checked before each.
    private func run(
        _ turn: FlowTurn, owner: FlowTurnOwner, events: FlowTurnEvents, errors: FlowTurnErrors
    ) async throws -> String {
        try turn.control.check()
        let agent = turn.agent
        var advertised = flags.clientCapabilities
        advertised.terminal = true
        let (permission, flags, config, rules, capabilities) = (permission, flags, config, permissionRules, advertised)
        let handle = try await owner.launch {
            try await ACPAgent.launch(
                agent: agent.agentCommand, argv: agent.agentArgv, cwd: agent.cwd, permission: permission,
                nonInteractivePermissions: flags.nonInteractivePolicy, permissionRules: rules,
                capabilities: capabilities, authCredentials: config.auth, authPolicy: flags.authPolicy,
                inheritStderr: flags.verbose,
                onRawWire: { direction, body in
                    guard let message = WireJSON(parsing: body) else { return }
                    errors.observe(message, inbound: direction == .inbound)
                    turn.onMessage(direction == .outbound, message)
                })
        }
        await onConnected?(handle.connection)
        await events.follow(handle.connection)
        try turn.control.check()
        let invocation = AgentInvocation(
            agentName: agent.agentName, agentCommand: agent.agentCommand, agentArgv: agent.agentArgv, cwd: agent.cwd)
        // acpx's flow runner's `sessionOptions`: the model, allowed tools and turns.
        var options = SessionAcpxState.SessionOptions()
        options.model = flags.model
        options.allowedTools = flags.allowedTools
        options.maxTurns = flags.maxTurns
        let session = try await ExecCommand.openSession(
            on: handle, agent: invocation, mcpServers: mcpServers,
            meta: SessionMeta.build(options: options, agentCommand: agent.agentCommand), model: flags.model,
            configOptions: [], timeoutMs: nil, quiet: ExecCommand.quietOutput(flags))
        events.opened(session.id)
        try turn.control.check()
        turn.onSessionReady(session.id)
        owner.opened(session.id)
        // acpx's client fails a prompt that needed a permission question nobody could be
        // asked with that, in place of how the prompt ended (`throwPromptPermissionFailureIfPresent`).
        let connection = handle.connection
        let unavailable = { FlowPromptUnavailable(acp: errors.match(FlowPromptUnavailable.message)) }
        errors.reset()
        do {
            _ = try await session.prompt(turn.prompt)
        } catch {
            if await connection.permissionStats(for: session.id).promptUnavailable { throw unavailable() }
            throw error
        }
        if await connection.permissionStats(for: session.id).promptUnavailable { throw unavailable() }
        return session.id
    }
}

/// acpx's `PermissionPromptUnavailableError`, as a flow's turn fails with it: the turn
/// needed a permission question nobody could be asked (`--non-interactive-permissions
/// fail`). acpx reports it as `PERMISSION_PROMPT_UNAVAILABLE`, exit 5, with the ACP error
/// its turn saw that says so (`attachAcpErrorPayload`): the client's own refusal.
struct FlowPromptUnavailable: Error, LocalizedError, OutputErrorMeta, AcpErrorCarrier {
    var acp: AcpErrorPayload?
    static let message = FileSystemPermissionError.promptUnavailable.description

    var errorDescription: String? { Self.message }
    var outputCode: String? { "PERMISSION_PROMPT_UNAVAILABLE" }
    var detailCode: String? { nil }
    var origin: String? { nil }
}

/// acpx's `AcpErrorTracker` for a flow's turn: the ACP errors on its wire since its prompt
/// went out — before that, since the agent started.
final class FlowTurnErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = AcpErrorTracker()

    func observe(_ message: WireJSON, inbound: Bool) {
        lock.withLock { tracker.observe(message, inbound: inbound) }
    }

    /// The prompt goes out: nothing seen before says how it fails.
    func reset() {
        lock.withLock { tracker.reset() }
    }

    func match(_ failureText: String) -> AcpErrorPayload? {
        lock.withLock { tracker.match(failureText: failureText) }
    }
}

/// acpx's `ownDirectClient`, as a flow's turn owns its agent: once the attempt stops the
/// turn — at its deadline, or an interrupt — the prompt out is cancelled and given 2.5 s
/// to settle (`cancelActivePrompt`), then the agent is closed; still starting, its launch
/// is called off.
final class FlowTurnOwner: @unchecked Sendable {
    /// How long acpx's `ownDirectClient` waits for the prompt it cancels.
    static let cancelWaitMilliseconds = 2_500

    private let lock = NSLock()
    private var launching: Task<ACPAgent, Error>?
    private var agent: ACPAgent?
    private var sessionId: SessionId?
    private var stopped = false
    private var stopping: Task<Void, Never>?

    /// What a stop finds, taken under the lock.
    private struct Held {
        let agent: ACPAgent?
        let sessionId: SessionId?
        let launching: Task<ACPAgent, Error>?
    }

    /// Launch the agent with `launch`, which a stop calls off.
    func launch(_ launch: @escaping @Sendable () async throws -> ACPAgent) async throws -> ACPAgent {
        let task = Task { try await launch() }
        if lock.withLock({ launching = task; return stopped }) { task.cancel() }
        let agent = try await task.value
        let stoppedMeanwhile = lock.withLock {
            self.agent = agent
            return stopped
        }
        if stoppedMeanwhile {
            // Stopped as it came up: nothing else is to be sent it.
            await agent.close()
            throw CancellationError()
        }
        return agent
    }

    /// The turn's session is open.
    func opened(_ sessionId: SessionId) {
        lock.withLock { self.sessionId = sessionId }
    }

    /// The attempt stopped the turn.
    func stop() {
        let held: Held? = lock.withLock {
            guard !self.stopped else { return nil }
            self.stopped = true
            return Held(agent: self.agent, sessionId: self.sessionId, launching: self.launching)
        }
        guard let held else { return }
        guard let running = held.agent else {
            held.launching?.cancel()
            return
        }
        let prompted = held.sessionId
        let task = Task {
            let connection = running.connection
            if let prompted, await connection.hasPromptInFlight(sessionId: prompted) {
                try? await connection.cancel(sessionId: prompted)
                _ = try? await withTimeout(milliseconds: Self.cancelWaitMilliseconds) {
                    await connection.waitForPromptToSettle(sessionId: prompted)
                }
            }
            await Self.close(running, afterUpdatesOf: prompted)
        }
        lock.withLock { self.stopping = task }
    }

    /// acpx's `closeOwnedClient`, which the turn ends with: the agent closed, once a stop
    /// under way has closed it.
    func close() async {
        let (agent, sessionId, stopping) = lock.withLock { (self.agent, self.sessionId, self.stopping) }
        await stopping?.value
        guard let agent else { return }
        await Self.close(agent, afterUpdatesOf: sessionId)
    }

    /// Close `agent` once every update of `sessionId` its connection has read is handled.
    /// Closing ends the connection's subscriptions there and then, so an update read but
    /// still on its way to them would be lost to the turn's record, though the turn's
    /// `events.ndjson` has it. acpx's client takes in all it has read before it closes.
    private static func close(_ agent: ACPAgent, afterUpdatesOf sessionId: SessionId?) async {
        if let sessionId { await agent.connection.waitForSessionUpdatesHandled(sessionId: sessionId) }
        await agent.close()
    }
}

/// A turn's session updates and client operations, handed to its hooks as the connection
/// has them — every one by the time the turn is over (``finish()``).
final class FlowTurnEvents: @unchecked Sendable {
    private let turn: FlowTurn
    private let lock = NSLock()
    private var connection: ACPAgentConnection?
    private var subscription: UUID?
    private var consumer: Task<Void, Never>?
    private var sessionId: SessionId?

    init(_ turn: FlowTurn) {
        self.turn = turn
    }

    /// Follow `connection`'s events from now on.
    func follow(_ connection: ACPAgentConnection) async {
        let (subscription, stream) = await connection.makeEventSubscription()
        let turn = self.turn
        let consumer = Task {
            for await event in stream {
                switch event {
                case .update(let notification): turn.onSessionUpdate(notification)
                case .clientOperation: turn.onClientOperation()
                default: break
                }
            }
        }
        lock.withLock {
            self.connection = connection
            self.subscription = subscription
            self.consumer = consumer
        }
    }

    /// The turn's session is open.
    func opened(_ sessionId: SessionId) {
        lock.withLock { self.sessionId = sessionId }
    }

    /// Stop following, once what the connection has read of the session is handed on.
    func finish() async {
        let (connection, subscription, consumer, sessionId) = lock.withLock {
            (self.connection, self.subscription, self.consumer, self.sessionId)
        }
        guard let connection, let subscription else { return }
        if let sessionId { await connection.waitForSessionUpdatesHandled(sessionId: sessionId) }
        await connection.endSubscription(subscription)
        await consumer?.value
    }
}
