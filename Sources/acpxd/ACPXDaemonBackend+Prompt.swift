import ACPXCore
import Foundation
import SwiftACP
import SwiftMCP

/// The daemon's prompt-turn machinery: `runPrompt` — validating a turn's
/// attachments, serializing turns per session, and persisting the turn as it
/// streams — plus the single attempt it retries when a held session has gone away.
extension ACPXDaemonBackend {
    /// Run a prompt against an existing session, streaming each update as a log
    /// notification and returning the agent's aggregate response text.
    ///
    /// The agent command and working directory are read from the session's
    /// persisted record (created by `newSession`) — there's no need to repeat them,
    /// just as the acpx CLI takes cwd from the process, not from each prompt.
    ///
    /// - Parameters:
    ///   - sessionId: an existing session id (acpx record id or ACP session id).
    ///     Reconnects to it, recreating the underlying session only if its rollout
    ///     is gone. Must not be empty.
    ///   - text: the prompt text. May be empty when `blocks` carries the turn.
    ///   - blocks: ACP content blocks to send after the text — an image, a
    ///     `resource_link` handing over a file, or inline resource text. Validated
    ///     before the turn is queued, and refused if the agent never advertised the
    ///     capability a block needs — see ``PromptBlock``.
    ///   - content: blocks sent as written, checked by acpx's rules instead of
    ///     `blocks`' — see ``PromptContent``. Not together with `blocks`.
    ///   - wait: when another turn is already running for this session, `true` (the
    ///     default) queues this one behind it; `false` rejects it immediately with a
    ///     "session busy" error instead of waiting.
    ///   - permissionMode: how this turn's permission requests and writes are
    ///     answered — see ``TurnPermissions``. `nil` approves everything.
    ///   - nonInteractivePermissions: `deny` (the default) or `fail`.
    ///   - terminalOutputCeiling: the caller's cap on terminal output, `0` for none —
    ///     omitted, the daemon's own `ACPX_TERMINAL_MAX_OUTPUT_BYTES`.
    ///   - model: the turn's `--model`, put on the session before the prompt and pinned.
    /// - Returns: the agent's aggregate response text for the turn. The turn's stop
    ///   reason is streamed separately as a final ``TurnEndedEvent`` log
    ///   notification (sent after the last `session/update`, before this returns).
    func runPrompt(
        sessionId rawSessionId: String, text: String,
        blocks: [PromptBlock]? = nil, content rawContent: [JSONValue]? = nil, wait: Bool = true,
        permissionMode: String? = nil, nonInteractivePermissions: String? = nil,
        streamWire: Bool = false, permissionPolicy: PermissionRules? = nil, terminalOutputCeiling: Int? = nil,
        model: String? = nil
    ) async throws -> String {
        let sessionId = rawSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { throw DaemonError.emptySessionId }
        // Checked before queueing, like the blocks: a bad mode is the caller's mistake,
        // not something to find out after waiting out another turn.
        let permissions = try TurnPermissions(
            mode: permissionMode, nonInteractive: nonInteractivePermissions, rules: permissionPolicy)
        let ceiling = try Self.terminalOutputCeiling(terminalOutputCeiling)
        // Validate before queueing: a malformed block should fail at once, not after
        // waiting out someone else's turn. The daemon's transport has a ceiling, so
        // the request size is capped here (a direct client has nothing in the way).
        let content: [ContentBlock]
        if let rawContent {
            guard blocks == nil else {
                throw PromptContent.ValidationError(message: "pass the prompt's blocks or its content, not both")
            }
            content = try PromptContent.contentBlocks(
                text: text, content: rawContent, requestLimit: PromptBlock.maxRequestBytes)
        } else {
            content = try PromptBlock.contentBlocks(
                text: text, blocks: blocks, requestLimit: PromptBlock.maxRequestBytes)
        }
        guard let initial = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let recordId = initial.acpxRecordId

        // One turn per session at a time: queue behind any in-flight turn (or, when
        // wait == false, reject), so concurrent CLI/MCP callers never drive one
        // agent — or persist one record — concurrently. Keyed by the record, whose
        // ACP session a fallback can replace.
        try await turnQueue.acquire(recordId, wait: wait)
        // `defer` can't await; the hop to the queue actor is safe because release
        // hands the slot to the next FIFO waiter regardless of when it lands.
        defer { Task { await turnQueue.release(recordId) } }

        // Reload the record *after* acquiring the slot: a turn we queued behind has
        // just persisted new history, and the persister must build on that, not on a
        // stale pre-wait snapshot (whose final flush would otherwise clobber it). By the
        // record id: that turn may also have moved the record to a new ACP session, and
        // the caller's id may be the one it replaced.
        guard let record = findRecord(recordId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let agentCommand = record.agentCommand
        let cwd = record.cwd
        let mcpServers = record.acpx?.mcpServers
        // Whether this turn starts on a connection the daemon already holds — the only
        // case in which a session-gone failure can mean the agent dropped the session
        // from under it (see the retry below).
        let wasHeld = live[recordId] != nil
        // Record the user's prompt once, up front, before connecting — acpx keeps the
        // prompt of a turn that fails, even one that never reached the agent. The
        // persister checkpoints the turn to disk on a debounce as updates stream in
        // (acpx's live checkpoint), draining the wire buffer into the event log on each
        // save. A session-gone retry reuses both, so the prompt isn't double-recorded.
        let eventBuffer = WireBuffer()
        let persister = TurnPersister(record: record, eventBuffer: eventBuffer)
        await persister.recordPrompt(content)
        // The turn's exchange, watched for the error a failure turns out to be.
        let errors = TurnErrorWatch()
        let requestedModel = model?.javaScriptTrimmed
        let turn = Turn(
            recordId: recordId, agentCommand: agentCommand, cwd: cwd, mcpServers: mcpServers, blocks: content,
            model: requestedModel?.isEmpty == false ? requestedModel : nil, permissions: permissions,
            terminalOutputCeiling: ceiling, persister: persister, eventBuffer: eventBuffer,
            streamWire: streamWire, errors: errors)
        // acpx keeps the prompt of a turn that fails, and what the agent said of it.
        return try await reportingFailure(of: recordId, errors: errors, saving: persister) {
            try await attemptWithRetry(turn, wasHeld: wasHeld)
        }
    }

    /// One turn's settings, as ``attemptPrompt(_:)`` needs them.
    struct Turn {
        let recordId: String
        let agentCommand: String
        let cwd: String
        let mcpServers: [McpServerConfig]?
        let blocks: [ContentBlock]
        /// The turn's `--model`, trimmed; `nil` without one.
        let model: String?
        let permissions: TurnPermissions
        /// The caller's cap on terminal output, `nil` for none.
        let terminalOutputCeiling: Int?
        let persister: TurnPersister
        let eventBuffer: WireBuffer
        let streamWire: Bool
        let errors: TurnErrorWatch
    }

    /// Run `body`; when it fails, tell the calling client how, the way acpx's queue
    /// owner tells its CLI — a ``TurnFailedEvent`` — and save the turn so far, then
    /// rethrow.
    func reportingFailure<T>(
        of recordId: String, errors: TurnErrorWatch, saving persister: TurnPersister? = nil,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch {
            let event = TurnFailure.event(for: error, shown: errors.match(error), sessionId: recordId)
            await Session.current?.sendLogNotification(
                LogMessage(level: .info, logger: recordId, data: toJSONValue(event)))
            await persister?.finish()
            throw error
        }
    }

    private func attemptWithRetry(_ turn: Turn, wasHeld: Bool) async throws -> String {
        do {
            return try await attemptPrompt(turn, retriesOnAFreshLaunch: wasHeld)
        } catch is RetriedOnAFreshLaunch {
            // A held session can disappear (the agent dropped it — e.g. after an
            // earlier failure). Evict the stale entry and try once more from a fresh
            // launch. Only retry for session-gone errors, never transient ones like
            // rate limits — and only for a session held before this turn: when the
            // turn connected it, the agent has just answered for a fresh launch, and a
            // refused reconnect (which reads like a gone session) would only be asked
            // again.
            //
            // A held agent can also exit just after `ensure` found it open. When none of
            // the turn reached it (`AgentExitedBeforeTheTurn`), the turn goes to a fresh
            // launch unseen; one it did reach is never sent twice. Nor is one the agent
            // answered at all (`TurnWireFeed.agentAnswered`): the attempt decides.
            await evict(turn.recordId)
            return try await attemptPrompt(turn, retriesOnAFreshLaunch: false)
        }
    }

    /// An attempt a fresh launch of the agent is to take over: see
    /// ``isFixedByAFreshLaunch(_:)``.
    struct RetriedOnAFreshLaunch: Error {
        let underlying: Error
    }

    /// A failure a fresh launch of the agent would not have: the held agent dropped the
    /// session, or exited before any of the turn reached it.
    func isFixedByAFreshLaunch(_ error: Error) -> Bool {
        isSessionGone(error) || error is AgentExitedBeforeTheTurn
    }

    /// Forwards what connecting an agent for a turn put on the wire to the MCP client
    /// the turn is for, before the turn's own messages — noting its errors on the way.
    static func forwardToClient(logger: String, errors: TurnErrorWatch? = nil) -> ConnectOutputHandler {
        let clientSession = Session.current
        return { messages in
            errors?.observe(messages)
            for message in messages {
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: logger, data: toJSONValue(message)))
            }
        }
    }

    /// - Parameter retriesOnAFreshLaunch: whether a failure a fresh launch would not
    ///   have (``isFixedByAFreshLaunch(_:)``) is retried on one, as long as the agent has
    ///   not answered the attempt. It then throws ``RetriedOnAFreshLaunch``, and nothing
    ///   of the attempt is shown: it does not fail the turn.
    private func attemptPrompt(_ turn: Turn, retriesOnAFreshLaunch: Bool) async throws -> String {
        let (recordId, blocks, permissions) = (turn.recordId, turn.blocks, turn.permissions)
        let (persister, eventBuffer, errors) = (turn.persister, turn.eventBuffer, turn.errors)
        // Nothing an earlier attempt showed says how this one fails — not even when it
        // fails to connect at all.
        errors.reset()
        // A reconnect that has to start a new session hands it to the persister, so the
        // turn's saves carry it on instead of writing the old session back; what the
        // connecting put on the wire goes to the calling client first.
        // This turn's permissions — acpx sends the mode with every prompt and the queue
        // owner applies it to that turn — are the live agent's from before connecting
        // on, as is its cap on terminal output. Turns are serialized per session, so no
        // other turn can be reading them meanwhile.
        let entry = try await ensure(
            recordId: recordId, agentCommand: turn.agentCommand, cwd: turn.cwd, mcpServers: turn.mcpServers,
            handlers: permissions.handlers, terminalOutputCeiling: turn.terminalOutputCeiling,
            requestedModel: turn.model,
            onRecordChange: { await persister.adopt($0) },
            onConnectOutput: Self.forwardToClient(logger: recordId, errors: errors))
        // The attempt proper starts once connected: a restore the agent refused while
        // connecting is on the wire, but it is not how this attempt fails.
        errors.reset()
        let connection = entry.agent.connection
        let boundSessionId = entry.session.id
        let sessionId = boundSessionId
        // Whether the turn itself — its prompt — may have reached the agent: from when it
        // starts to be written, unless the write fails. acpx counts a prompt once it is
        // written (`onPromptRequestWritten`); counting it from before, an agent that took
        // it and exited at once never gets it twice, and one whose closed stdin refused it
        // gets it from a fresh launch. The `--model` asked for before it is not — a fresh
        // launch asks for it again, which does no harm. Cleared when the turn ends.
        let wrote = WriteMark()
        // The calling client's MCP session — stream updates to it as log notifications.
        let clientSession = Session.current
        let wireFeed = TurnWireFeed(
            streamWire: turn.streamWire, provisional: retriesOnAFreshLaunch, logger: recordId, to: clientSession)
        // The prompt's result as it crossed the wire: its usage and cost go to the
        // client with the turn's end, in the shape the agent sent them.
        let promptResult = PromptResultCapture()
        entry.agent.rawWire.set { direction, body in
            errors.observe(direction, body)
            wireFeed.observe(direction, body)
            promptResult.observe(direction, body)
        }
        entry.agent.rawWire.onDelivery { body, delivery in
            guard WireJSON(parsing: body)?["method"] == .text("session/prompt") else { return }
            if delivery == .writing { wrote.mark() } else { wrote.unmark() }
        }
        defer {
            entry.agent.rawWire.set(nil)
            entry.agent.rawWire.onDelivery(nil)
        }

        // Tee every JSON-RPC line on the wire into the buffer; the persister drains
        // it into the event log on each checkpoint. Cleared when the turn ends.
        await connection.setWireObserver { line in eventBuffer.append(line) }

        // Subscribe before prompting so no event is missed, then drain the
        // subscription deterministically: ending it (after `prompt` returns)
        // finishes the stream, so the consumer task completes having sent every
        // event — in order — and built the agent's message content for the turn.
        let (subscriptionId, stream) = await connection.makeEventSubscription()
        let consumer = Task {
            await Self.relay(
                stream, of: boundSessionId, as: sessionId, into: persister, to: clientSession)
        }
        do {
            if let model = turn.model {
                try await applyPromptModel(model, to: entry, persister: persister, agentCommand: turn.agentCommand)
            }
            let response = try await entry.session.prompt(blocks)
            await connection.endSubscription(subscriptionId)
            await connection.setWireObserver(nil)
            let fullText = await consumer.value
            // The exchange ends with the prompt's response; the turn's end follows it.
            await wireFeed.finish()
            // Capture the token breakdown the agent reports on the response (Claude
            // Code does; acpx misses this — it only reads usage_update._meta.usage).
            if let usage = response.usage { await persister.applyResponseUsage(usage) }
            await persister.applyLifecycle(entry.agent.lifecycle)
            // Final checkpoint: stamp timestamps and flush the completed turn —
            // including any wire lines still buffered for the event log.
            await persister.finish()
            // Demote the stop reason to a streamed event: emit it last, after every
            // update, so a client reconstructing the turn sees it in order. It carries
            // how the turn's permissions went, which decides the CLI's exit code.
            let permissionStats = await connection.permissionStats(for: boundSessionId)
            await clientSession?.sendLogNotification(
                LogMessage(
                    level: .info, logger: sessionId,
                    data: toJSONValue(TurnEndedEvent(
                        stopReason: response.stopReason.rawValue, permissions: permissionStats,
                        usage: promptResult.usage, cost: promptResult.cost))))
            return fullText
        } catch {
            await connection.endSubscription(subscriptionId)
            await connection.setWireObserver(nil)
            // Everything the agent said before failing still goes out, and is kept, as
            // acpx shows and records it — then the error itself.
            _ = await consumer.value
            let failure = ACPAgentConnection.isConnectionClosed(error) && !wrote.happened
                ? AgentExitedBeforeTheTurn(underlying: error) : error
            let retried = retriesOnAFreshLaunch && isFixedByAFreshLaunch(failure) && !wireFeed.agentAnswered
            // How the agent ended, if it did, goes into the record the failure saves — once
            // it has: an agent whose connection is gone can still be running (its stdout
            // closed, say), and is ended before its pid would be kept.
            if ACPAgentConnection.isConnectionClosed(error) { await entry.agent.close() }
            await persister.applyLifecycle(entry.agent.lifecycle)
            await wireFeed.finish(showingHeld: !retried)
            throw retried ? RetriedOnAFreshLaunch(underlying: failure) : failure
        }
    }
}

extension ACPXDaemonBackend {
    /// What one attempt's event subscription carries, relayed as the turn goes: each of
    /// the session's updates folded into the persister (which debounce-saves the record)
    /// and streamed to the calling client with the agent's requests and the client's
    /// diagnostics, in order. Returns the agent's message text.
    private static func relay(
        _ stream: AsyncStream<ConnectionEvent>, of boundSessionId: SessionId, as sessionId: String,
        into persister: TurnPersister, to clientSession: Session?
    ) async -> String {
        // Accumulate the full streamed text for the MCP result, and fold each
        // update into the persister (which debounce-saves the record as it goes).
        var fullText = ""
        for await event in stream {
            switch event {
            case .update(let note) where note.sessionId == boundSessionId:
                if case .agentMessageChunk(let block) = note.update, let chunk = block.text {
                    fullText += chunk
                }
                await persister.apply(note.update)
                let payload = SessionNotification(sessionId: boundSessionId, update: note.update)
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: sessionId, data: toJSONValue(payload)))
            case .inboundRequest(let request)
                where request.sessionId == nil || request.sessionId == boundSessionId:
                // The agent's own request (a file write, a permission question), and
                // the client's refusal of it: acpx's formatter prints both, so they
                // stream in order with the updates.
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: sessionId, data: toJSONValue(request)))
            case .clientOperation(let operation)
                where operation.sessionId == nil || operation.sessionId == boundSessionId:
                // A client-side diagnostic the connection reported mid-turn — a
                // permission refusal that may end the turn (see `CodexCompat`).
                // Streamed in order like an update, so the CLI renders it in place;
                // not part of the conversation history (the wire log has the
                // annotated response).
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: sessionId, data: toJSONValue(operation)))
            default:
                break
            }
        }
        return fullText
    }

    /// acpx's `applyPromptModelIfAdvertised`: a turn's `--model` goes onto the session
    /// before the prompt — checked against what the session advertises, not sent when
    /// it is already the current model — and is pinned in the record the turn saves.
    /// A model the session cannot take fails the turn before the prompt goes out.
    func applyPromptModel(
        _ model: String, to entry: Live, persister: TurnPersister, agentCommand: String
    ) async throws {
        let application = try await ModelApplication.applyRequestedModel(
            connection: entry.agent.connection, sessionId: entry.session.id, requestedModel: model,
            models: ModelSupport.advertisedModelState(await persister.acpx), agentCommand: agentCommand)
        guard application.applied else { return }
        let response = application.response
        await persister.adopt { record in
            var acpx = record.acpx ?? SessionAcpxState()
            ModelSupport.applyModelSelection(model, response: response, to: &acpx)
            record.acpx = acpx
        }
    }
}

/// One turn's permissions, as acpx sends them with every prompt: the mode
/// (`--approve-all` / `--approve-reads` / `--deny-all`) and what a write needing
/// confirmation does without a terminal. The daemon swaps the live agent's handlers
/// to these for the turn — acpx's queue owner applies each prompt's mode to that turn.
struct TurnPermissions: Sendable {
    let handlers: ACPClientHandlers

    /// - Parameters:
    ///   - mode: `approve-all`, `approve-reads` or `deny-all`. `nil` — a caller that
    ///     predates the parameter — keeps the old behaviour of approving everything.
    ///   - nonInteractive: `deny` (the default) or `fail`.
    ///   - rules: the turn's per-tool permission policy, which comes before `mode`.
    init(mode: String?, nonInteractive: String?, rules: PermissionRules? = nil) throws {
        let policy: PermissionPolicy
        if let mode {
            guard let parsed = PermissionPolicy(acpxMode: mode) else {
                throw DaemonError.invalidPermissionMode(mode)
            }
            policy = parsed
        } else {
            policy = .approveAll
        }
        let unanswerable: NonInteractivePermissionPolicy
        if let nonInteractive {
            guard let parsed = NonInteractivePermissionPolicy(rawValue: nonInteractive) else {
                throw DaemonError.invalidNonInteractivePermissions(nonInteractive)
            }
            unanswerable = parsed
        } else {
            unanswerable = .deny
        }
        // `.none`: the daemon's own terminal, if it has one, is not the user's. Like
        // acpx's detached queue owner, it never asks — a write needing confirmation is
        // refused, or refused as unanswerable under `fail`.
        handlers = .standard(
            permission: policy, nonInteractivePermissions: unanswerable, terminal: .none, rules: rules)
    }
}

/// The held agent had exited before any of the turn reached it: its connection was
/// already closed when the prompt was sent. Nothing was seen by it, so the turn can go
/// to a fresh launch. Reads as the closed connection it is.
struct AgentExitedBeforeTheTurn: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

/// Set once anything is written to the agent. Marked from the transport's writer
/// task, so lock-protected.
final class WriteMark: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    func mark() {
        lock.withLock { marked = true }
    }

    func unmark() {
        lock.withLock { marked = false }
    }

    var happened: Bool {
        lock.withLock { marked }
    }

}
