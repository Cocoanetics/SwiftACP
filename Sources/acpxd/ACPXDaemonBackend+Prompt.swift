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
    ///   - limits: the turn's `--timeout`, `--prompt-retries` and `--ttl` (``PromptLimits``).
    /// - Returns: the agent's aggregate response text for the turn. The turn's stop
    ///   reason is streamed separately as a final ``TurnEndedEvent`` log
    ///   notification (sent after the last `session/update`, before this returns).
    func runPrompt(
        sessionId rawSessionId: String, text: String,
        blocks: [PromptBlock]? = nil, content rawContent: [JSONValue]? = nil, wait: Bool = true,
        permissionMode: String? = nil, nonInteractivePermissions: String? = nil,
        streamWire: Bool = false, permissionPolicy: PermissionRules? = nil, terminalOutputCeiling: Int? = nil,
        model: String? = nil, limits: PromptLimits? = nil
    ) async throws -> String {
        let sessionId = rawSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { throw DaemonError.emptySessionId }
        // acpx's queue owner refuses a negative retry count, and takes a timeout that is
        // not positive as none. One longer than a timer takes is refused, as acpx's CLI
        // refuses it: the owner's timer would fire at once.
        let retries = limits?.promptRetries ?? 0
        guard retries >= 0 else { throw DaemonError.invalidPromptRetries(retries) }
        let timeout = limits?.timeoutMs.flatMap { $0 > 0 ? $0 : nil }
        if let timeout, timeout > JavaScriptNumber.maxTimerDelayMs { throw DaemonError.invalidTimeout(timeout) }
        // So is a TTL, as acpx's CLI refuses `--ttl` past it.
        if let ttl = limits?.ttlMs, ttl > JavaScriptNumber.maxTimerDelayMs { throw DaemonError.invalidTTL(ttl) }
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
        // The session is held from here on, as acpx's queue owner holds it: until it has
        // had no prompt for its TTL once this turn is over.
        turnStarts(recordId, ttlMs: limits?.ttlMs)
        // `defer` can't await; the hop to the queue actor is safe because release
        // hands the slot to the next FIFO waiter regardless of when it lands.
        defer {
            Task {
                await turnQueue.release(recordId)
                await self.turnEnded(recordId)
            }
        }
        // The turn runs from here: from now on a cancel is its (``cancelSession(sessionId:)``).
        let control = TurnControl()
        turns[recordId] = control
        defer { turns[recordId] = nil }

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
        // Each prompt builds the record's `acpx` block anew, as acpx's does
        // (`preparePromptConversation`).
        var prompted = record
        prompted.acpx = record.acpx?.cloned()
        // The turn's journal records are keyed by its id, as acpx's by its queue request's.
        let persister = TurnPersister(
            record: prompted, eventBuffer: eventBuffer, requestId: control.id.uuidString.lowercased())
        await persister.recordPrompt(content)
        // The turn's exchange, watched for the error a failure turns out to be.
        let errors = TurnErrorWatch()
        let requestedModel = model?.javaScriptTrimmed
        let turn = Turn(
            id: control.id, recordId: recordId, agentCommand: agentCommand, cwd: cwd, mcpServers: mcpServers,
            blocks: content,
            model: requestedModel?.isEmpty == false ? requestedModel : nil, permissions: permissions,
            terminalOutputCeiling: ceiling, timeoutMilliseconds: timeout, promptRetries: retries,
            persister: persister, eventBuffer: eventBuffer, streamWire: streamWire, errors: errors)
        // acpx keeps the prompt of a turn that fails, and what the agent said of it.
        return try await reportingFailure(of: recordId, errors: errors, saving: persister) {
            try await beginTurn(on: persister, recordId: recordId)
            return try await attemptWithRetry(turn, wasHeld: wasHeld)
        }
    }

    /// One turn's settings, as ``attemptPrompt(_:)`` needs them.
    struct Turn {
        /// Its ``TurnControl``'s.
        let id: UUID
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
        /// The turn's `--timeout` for each of its steps, `nil` for none.
        let timeoutMilliseconds: Int?
        /// The turn's `--prompt-retries`.
        let promptRetries: Int
        let persister: TurnPersister
        let eventBuffer: WireBuffer
        let streamWire: Bool
        let errors: TurnErrorWatch
    }

    /// Run `body`; when it fails, save the turn so far and end its journal with the
    /// failure, then tell the calling client how, the way acpx's queue owner tells its
    /// CLI — a ``TurnFailedEvent`` — and rethrow. A journal that cannot be ended fails
    /// the turn in its place, as acpx's does.
    func reportingFailure<T>(
        of recordId: String, errors: TurnErrorWatch, saving persister: TurnPersister? = nil,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch {
            await persister?.finish()
            var failure = error
            if let unwritten = await persister?.endTurn(TurnFailure.journalResult(for: error)) { failure = unwritten }
            let event = TurnFailure.event(for: failure, shown: errors.match(failure), sessionId: recordId)
            await Session.current?.sendLogNotification(
                LogMessage(level: .info, logger: recordId, data: toJSONValue(event)))
            throw failure
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
        let (recordId, permissions) = (turn.recordId, turn.permissions)
        let (persister, eventBuffer, errors) = (turn.persister, turn.eventBuffer, turn.errors)
        // Nothing an earlier attempt showed says how this one fails — not even when it
        // fails to connect at all.
        errors.reset()
        // Until this attempt's prompt goes out, a cancel waits for it.
        turns[recordId]?.prompt = nil
        turns[recordId]?.answered = false
        // A reconnect that has to start a new session hands it to the persister, so the
        // turn's saves carry it on instead of writing the old session back; what the
        // connecting put on the wire goes to the calling client first.
        // This turn's permissions — acpx sends the mode with every prompt and the queue
        // owner applies it to that turn — are the live agent's from before connecting
        // on, as is its cap on terminal output. Turns are serialized per session, so no
        // other turn can be reading them meanwhile.
        let entry = try await ensure(
            recordId: recordId, agentCommand: turn.agentCommand, cwd: turn.cwd, mcpServers: turn.mcpServers,
            settings: CallerSettings(
                handlers: permissions.handlers, terminalOutputCeiling: turn.terminalOutputCeiling,
                timeoutMilliseconds: turn.timeoutMilliseconds),
            requestedModel: turn.model, turnAcpx: await persister.acpx,
            onRecordChange: { await persister.adopt($0) },
            onConnectOutput: Self.forwardToClient(logger: recordId, errors: errors),
            // acpx logs the exchange that connects the agent with the turn — all of it,
            // a reconnect the agent refused too.
            onConnectWire: { _, body in eventBuffer.append(body) })
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
        let turnId = turn.id
        watchTheWire(of: entry, for: turn, feeding: wireFeed, result: promptResult, wrote: wrote)
        defer {
            entry.agent.rawWire.set(nil)
            entry.agent.rawWire.onDelivery(nil)
        }

        // Subscribe before prompting so no event is missed, then drain the
        // subscription deterministically: ending it (after `prompt` returns)
        // finishes the stream, so the relay completes having sent every event — in
        // order — and built the agent's message content for the turn.
        let announceAnswer = Self.announcingTheAnswer(as: sessionId, to: clientSession) { [self] in
            await self.promptAnswered(recordId: recordId, turn: turnId)
        }
        let relay = await TurnRelay(
            connection: connection, sessionId: boundSessionId, logger: recordId, to: clientSession
        ) { stream in
            await Self.relay(
                stream, of: boundSessionId, as: sessionId, into: persister, to: clientSession,
                onAnswered: announceAnswer)
        }
        do {
            if let model = turn.model {
                try await applyPromptModel(
                    model, to: entry, persister: persister, agentCommand: turn.agentCommand,
                    timeoutMilliseconds: turn.timeoutMilliseconds)
                // The model's request is shown before what the prompt says, as acpx shows it.
                await wireFeed.drain()
            }
            // Connected: saved before the prompt goes out, as acpx saves then.
            await persister.checkpoint()
            // The turn's permissions are those of every attempt at its prompt, and of the
            // pauses between them, as acpx's client counts them across its run.
            let countedBefore = await connection.permissionTotals(for: boundSessionId)
            let outcome = try await promptWithRetries(turn, on: entry, relay: relay, wireFeed: wireFeed)
            let response = outcome.response
            await relay.end()
            let fullText = await relay.text()
            // The exchange ends with the prompt's response; the turn's end follows it.
            await wireFeed.finish()
            // Capture the token breakdown the agent reports on the response (Claude
            // Code does; acpx misses this — it only reads usage_update._meta.usage).
            if let usage = response.usage { await persister.applyResponseUsage(usage) }
            await persister.applyLifecycle(entry.agent.lifecycle)
            // Final checkpoint: stamp timestamps and flush the completed turn —
            // including any messages still buffered for the event log.
            await persister.finish()
            // The journal has the turn's result before the calling client hears of it, as
            // acpx's has. One it cannot write fails the turn.
            if let unwritten = await persister.endTurn(Self.journalResult(of: response, answer: promptResult)) {
                throw unwritten
            }
            // The turn's end goes last, its permissions read only now that it is over.
            let permissions = outcome.sent
                ? await connection.permissionTotals(for: boundSessionId).counted(since: countedBefore)
                : PermissionStats()
            await Self.announceTheEnd(
                of: response, permissions: permissions, result: promptResult, as: sessionId, to: clientSession)
            return fullText
        } catch let unwritten as SessionJournalWriteError {
            // The prompt is over, and its end said all it has to.
            throw unwritten
        } catch {
            await relay.end()
            // Everything the agent said before failing still goes out, and is kept, as
            // acpx shows and records it — then the error itself.
            _ = await relay.text()
            let failure = ACPAgentConnection.isConnectionClosed(error) && !wrote.happened
                ? AgentExitedBeforeTheTurn(underlying: error) : error
            let retried = retriesOnAFreshLaunch && isFixedByAFreshLaunch(failure) && !wireFeed.agentAnswered
                && turns[recordId]?.retried != true
            // How the agent ended, if it did, goes into the record the failure saves — once
            // it has: an agent whose connection is gone can still be running (its stdout
            // closed, say), and is ended before its pid would be kept.
            if ACPAgentConnection.endedTheConnection(error) { await entry.agent.close() }
            await persister.applyLifecycle(entry.agent.lifecycle)
            await wireFeed.finish(showingHeld: !retried)
            throw retried ? RetriedOnAFreshLaunch(underlying: failure) : failure
        }
    }
}

extension ACPXDaemonBackend {
    /// Watch an attempt's exchange as it crosses the wire: for how it fails, for the
    /// calling client, and for the prompt's answer — whose arrival marks the turn
    /// answered at once, from the reader's thread, before the connection has even handed
    /// it on, as acpx's client clears its active prompt at the answer. The note that the
    /// prompt went out comes from the writer's thread; it reaches this actor as the turn
    /// goes on, and is dropped once the turn has ended.
    func watchTheWire(
        of entry: Live, for turn: Turn, feeding wireFeed: TurnWireFeed, result promptResult: PromptResultCapture,
        wrote: WriteMark
    ) {
        let (recordId, turnId, errors) = (turn.recordId, turn.id, turn.errors)
        let (connection, sessionId) = (entry.agent.connection, entry.session.id)
        let eventBuffer = turn.eventBuffer
        entry.agent.rawWire.set { [self] direction, body in
            // Into the event log with the turn's next save, as the bytes the message was.
            eventBuffer.append(body)
            errors.observe(direction, body)
            wireFeed.observe(direction, body)
            if promptResult.observe(direction, body) {
                Task { await self.promptAnswered(recordId: recordId, turn: turnId) }
            }
        }
        entry.agent.rawWire.onDelivery { [self] body, delivery in
            guard WireJSON(parsing: body)?["method"] == .text("session/prompt") else { return }
            guard delivery == .writing else { return wrote.unmark() }
            wrote.mark()
            Task { await self.promptWritten(recordId: recordId, turn: turnId, to: connection, sessionId: sessionId) }
        }
    }

    /// acpx's `applyPromptModelIfAdvertised`: a turn's `--model` goes onto the session
    /// before the prompt — checked against what the session advertises, not sent when
    /// it is already the current model — and is pinned in the record the turn saves.
    /// A model the session cannot take fails the turn before the prompt goes out.
    func applyPromptModel(
        _ model: String, to entry: Live, persister: TurnPersister, agentCommand: String,
        timeoutMilliseconds: Int? = nil
    ) async throws {
        let application = try await ModelApplication.applyRequestedModel(
            connection: entry.agent.connection, sessionId: entry.session.id, requestedModel: model,
            models: ModelSupport.advertisedModelState(await persister.acpx), agentCommand: agentCommand,
            timeoutMilliseconds: timeoutMilliseconds)
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
