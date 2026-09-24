import Foundation
import JSONFoundation
import JSONRPCWire

// A session on a launched agent (``ACPAgent``), gated like it: agents are spawned only
// where a process can be. Split from `ACPAgent.swift` to keep each file inside the
// 500-line limit.
#if os(macOS) || os(Linux) || os(Windows)

/// A live session you can prompt. Bound to one `sessionId` on one agent.
public struct ACPSession: Sendable {
    public let id: SessionId
    public let agent: ACPAgent
    /// The mode state reported at creation (e.g. Codex's "read-only"/"auto").
    public let modes: SessionModeState?
    /// The `_meta` of the agent's reply that opened the session — `session/new`,
    /// `session/load` or `session/resume` — where an agent names its own session id.
    public let meta: JSONValue?
    /// The config options that reply advertised, when it named any.
    public let configOptions: [JSONValue]?
    /// The legacy `models` block that reply advertised, when it had one.
    public let models: JSONValue?

    public init(
        id: SessionId, agent: ACPAgent, modes: SessionModeState? = nil, meta: JSONValue? = nil,
        configOptions: [JSONValue]? = nil, models: JSONValue? = nil
    ) {
        self.id = id
        self.agent = agent
        self.modes = modes
        self.meta = meta
        self.configOptions = configOptions
        self.models = models
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
    /// once the turn ends. Deterministic — no updates are dropped. Any client
    /// operation the connection reported during the turn (a permission refusal
    /// that may end it — see ``CodexCompat``) is in ``PromptOutcome/clientOperations``;
    /// to observe those live as well, use ``run(_:meta:onUpdate:onClientOperation:)``.
    @discardableResult
    public func run(
        _ blocks: [ContentBlock],
        meta: JSONValue? = nil,
        onUpdate: (@Sendable (SessionUpdate) -> Void)? = nil
    ) async throws -> PromptOutcome {
        try await runTurn(blocks, meta: meta, onUpdate: onUpdate, onClientOperation: nil)
    }

    /// Like ``run(_:meta:onUpdate:)``, additionally passing each client operation
    /// the connection reports during the turn to `onClientOperation`, in order with
    /// the updates. Both closures are required: keeping this a separate overload
    /// (rather than a defaulted fourth parameter) is what keeps an unlabeled
    /// trailing closure bound to `onUpdate` in every language mode — Swift 5 mode
    /// would otherwise backward-match it to the last closure parameter.
    @discardableResult
    public func run(
        _ blocks: [ContentBlock],
        meta: JSONValue? = nil,
        onUpdate: @escaping @Sendable (SessionUpdate) -> Void,
        onClientOperation: @escaping @Sendable (ClientOperation) -> Void
    ) async throws -> PromptOutcome {
        try await runTurn(blocks, meta: meta, onUpdate: onUpdate, onClientOperation: onClientOperation)
    }

    /// As ``run(_:meta:onUpdate:onClientOperation:)``, also handing over each request
    /// the agent makes of this client — see ``InboundRequest`` — in wire order with the
    /// updates.
    @discardableResult
    public func run(
        _ blocks: [ContentBlock],
        meta: JSONValue? = nil,
        onUpdate: @escaping @Sendable (SessionUpdate) -> Void,
        onClientOperation: @escaping @Sendable (ClientOperation) -> Void,
        onInboundRequest: @escaping @Sendable (InboundRequest) -> Void
    ) async throws -> PromptOutcome {
        try await runTurn(
            blocks, meta: meta, onUpdate: onUpdate, onClientOperation: onClientOperation,
            onInboundRequest: onInboundRequest)
    }

    @discardableResult
    public func run(
        _ text: String,
        meta: JSONValue? = nil,
        onUpdate: (@Sendable (SessionUpdate) -> Void)? = nil
    ) async throws -> PromptOutcome {
        try await runTurn([.text(text)], meta: meta, onUpdate: onUpdate, onClientOperation: nil)
    }

    @discardableResult
    public func run(
        _ text: String,
        meta: JSONValue? = nil,
        onUpdate: @escaping @Sendable (SessionUpdate) -> Void,
        onClientOperation: @escaping @Sendable (ClientOperation) -> Void
    ) async throws -> PromptOutcome {
        try await runTurn([.text(text)], meta: meta, onUpdate: onUpdate, onClientOperation: onClientOperation)
    }

    /// The shared turn loop behind the `run` overloads: one event subscription,
    /// drained in wire order, feeding the callbacks and the collected outcome.
    private func runTurn(
        _ blocks: [ContentBlock],
        meta: JSONValue?,
        onUpdate: (@Sendable (SessionUpdate) -> Void)?,
        onClientOperation: (@Sendable (ClientOperation) -> Void)?,
        onInboundRequest: (@Sendable (InboundRequest) -> Void)? = nil
    ) async throws -> PromptOutcome {
        let (subscriptionId, stream) = await agent.connection.makeEventSubscription()
        let sessionId = id
        let collector = TurnCollector()
        let consumer = Task {
            for await event in stream {
                switch event {
                case .update(let note) where note.sessionId == sessionId:
                    if case .agentMessageChunk(let block) = note.update, let text = block.text {
                        await collector.append(text)
                    }
                    onUpdate?(note.update)
                case .clientOperation(let operation)
                    where operation.sessionId == nil || operation.sessionId == sessionId:
                    await collector.record(operation)
                    onClientOperation?(operation)
                case .inboundRequest(let request)
                    where request.sessionId == nil || request.sessionId == sessionId:
                    onInboundRequest?(request)
                default:
                    break
                }
            }
        }
        do {
            let response = try await prompt(blocks, meta: meta)
            await agent.connection.endSubscription(subscriptionId)
            await consumer.value
            return await PromptOutcome(
                stopReason: response.stopReason, text: collector.text, usage: response.usage,
                clientOperations: collector.operations)
        } catch {
            await agent.connection.endSubscription(subscriptionId)
            consumer.cancel()
            throw error
        }
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
    /// The session's cumulative token counters from the prompt response, when
    /// the agent reports them (Claude Code's adapter does; Codex sends none).
    public var usage: PromptUsage?
    /// The client operations the connection reported during the turn, in order —
    /// a permission refusal that may end the turn (see ``CodexCompat``); usually empty.
    public var clientOperations: [ClientOperation]

    public init(
        stopReason: StopReason, text: String, usage: PromptUsage? = nil,
        clientOperations: [ClientOperation] = []
    ) {
        self.stopReason = stopReason
        self.text = text
        self.usage = usage
        self.clientOperations = clientOperations
    }
}

/// A tiny actor that accumulates a turn's streamed text and reported client
/// operations without data races.
actor TurnCollector {
    private(set) var text = ""
    private(set) var operations: [ClientOperation] = []
    func append(_ chunk: String) { text += chunk }
    func record(_ operation: ClientOperation) { operations.append(operation) }
}

#endif
