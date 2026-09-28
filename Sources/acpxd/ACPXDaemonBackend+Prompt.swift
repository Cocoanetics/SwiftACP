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
    ///   - sessionOptions: the turn's `--model`, put on the session before the prompt and
    ///     pinned, and its `--allowed-tools`, `--max-turns` and `--system-prompt`: all of
    ///     them sent as `_meta` if the turn has to connect the session's agent.
    ///   - limits: the turn's `--timeout`, `--prompt-retries` and `--ttl` (``PromptLimits``).
    /// - Returns: the agent's aggregate response text for the turn. The turn's stop
    ///   reason is streamed separately as a final ``TurnEndedEvent`` log
    ///   notification (sent after the last `session/update`, before this returns).
    func runPrompt(
        sessionId rawSessionId: String, text: String,
        blocks: [PromptBlock]? = nil, content rawContent: [JSONValue]? = nil, wait: Bool = true,
        permissionMode: String? = nil, nonInteractivePermissions: String? = nil,
        streamWire: Bool = false, permissionPolicy: PermissionRules? = nil, terminalOutputCeiling: Int? = nil,
        sessionOptions: PromptSessionOptions? = nil, limits: PromptLimits? = nil, direct: Bool = false,
        fs: Bool? = nil, authPolicy: String? = nil, turnToken: String? = nil, callerConfig: CallerConfig? = nil,
        verbose: Bool = false, environment: [String: String]? = nil
    ) async throws -> String {
        let sessionId = rawSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { throw DaemonError.emptySessionId }
        let (retries, timeout) = try Self.checkedLimits(limits)
        // Checked before queueing, like the blocks: a bad mode is the caller's mistake,
        // not something to find out after waiting out another turn.
        let permissions = try TurnPermissions(
            mode: permissionMode, nonInteractive: nonInteractivePermissions, rules: permissionPolicy)
        let ceiling = try Self.terminalOutputCeiling(terminalOutputCeiling)
        let content = try Self.promptContent(text: text, blocks: blocks, content: rawContent)
        guard let initial = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let recordId = initial.acpxRecordId

        // The prompt begins as acpx's queue owner begins the prompt task it takes
        // (`runPromptTurn`): at once, unless another prompt of the session runs or waits
        // before it — then once those are over. Keyed by the record, whose ACP session a
        // fallback can replace. When `wait` is false, a session running anything rejects it.
        // Begun, the turn is the session's before it holds the session: a cancel is its
        // (``cancelSession(sessionId:)``), and so is a control sent, run on the prompt's
        // agent once the prompt goes out (acpx's `beginPrompt`). A turn that ends before
        // then fails the controls still waiting. A direct turn — a flow's — begins apart from
        // the owner's line, as acpx's `sendSessionDirect` takes only the session's turn (#225).
        let started: StartedTurn
        var heldTheSlot: Bool
        do {
            (started, heldTheSlot) = try await startTurn(
                recordId, direct: direct, wait: wait, turnToken: turnToken, queueMaxDepth: limits?.queueMaxDepth)
        } catch let refused as QueueOwnerShuttingDown {
            return try await failedBeforeItsAttempt(refused, of: recordId, direct: direct)
        } catch let refused as QueueOwnerOverloaded {
            return try await failedBeforeItsAttempt(refused, of: recordId, direct: direct)
        }
        let control = started.control
        defer { turnOver(recordId, started, heldTheSlot: heldTheSlot) }
        // One turn per session at a time, so concurrent CLI/MCP callers never drive one
        // agent — or persist one record — concurrently: the prompt waits for what holds the
        // session — a direct turn, the controls sent before it began — as acpx's waits for the
        // session's turn (`waitForSessionTurn`): within its `--timeout`, until a cancel ends
        // the wait, the turn cancelled then with nothing sent (#225).
        if !heldTheSlot {
            do {
                try await takeSlot(for: recordId, turn: control.id, within: direct ? nil : timeout)
            } catch let timedOut as TimeoutError {
                return try await failedBeforeItsAttempt(timedOut, of: recordId, direct: direct)
            } catch where turnControl(recordId, control.id)?.cancelAsked == true {
                return await Self.endedCancelled(as: initial.acpSessionId)
            }
            heldTheSlot = true
        }
        changeTurn(recordId, control.id) { $0.running = true }
        // acpx's `prompt.total` runs from here, as its turn has the session (`runOwnedSessionPrompt`).
        let ownedAt = ContinuousClock.now
        // Begun for a session another took the place of since, it is refused (#219 review).
        if turnControl(recordId, control.id)?.refused == true {
            return try await failedBeforeItsAttempt(QueueOwnerShuttingDown(inLine: true), of: recordId, direct: direct)
        }
        // A free slot is had at once, however the prompt was called off meanwhile: then it
        // ends here, nothing sent and nothing kept — a direct turn's agent with it, as acpx's
        // closes the client it was handed however it ends, from a task this cancellation
        // cannot cut short (#219 review).
        if Task.isCancelled {
            if direct { await Task { await self.evict(recordId) }.value }
            throw CancellationError()
        }
        // The session is held from here on, as acpx's queue owner holds it: until it has
        // had no prompt for its TTL once this turn is over. A direct turn has no owner, as
        // acpx's `sendSessionDirect` has none: its agent goes with it.
        if !direct {
            turnStarts(recordId, ttlMs: limits?.ttlMs, environment: environment, queueMaxDepth: limits?.queueMaxDepth)
        }

        // Reload the record *after* acquiring the slot: a turn we queued behind has
        // just persisted new history, and the persister must build on that, not on a
        // stale pre-wait snapshot (whose final flush would otherwise clobber it). By the
        // record id: that turn may also have moved the record to a new ACP session, and
        // the caller's id may be the one it replaced. A direct turn that finds it gone lets
        // its agent go, as acpx's closes the client it was handed however it ends (#219 review).
        let record = try await lettingDirectAgentGo(direct, recordId) {
            guard let record = findRecord(recordId) else { throw DaemonError.sessionNotFound(sessionId) }
            return record
        }
        // Cancelled as it took the session, it ends now, as acpx's prompt ends cancelled once
        // it holds the session (`runSessionPrompt`): nothing sent, and nothing kept of it.
        if turnControl(recordId, control.id)?.cancelAsked == true {
            // A direct turn's agent goes with it, as acpx closes the client it was handed however it ends.
            if direct { await evict(recordId) }
            return await Self.endedCancelled(as: record.acpSessionId)
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
        // The turn's journal records are keyed by its id, as acpx's by its queue request's. A
        // direct turn is no queue request, and its journal has only its messages.
        let persister = TurnPersister(
            record: prompted, eventBuffer: eventBuffer, requestId: direct ? nil : control.id.uuidString.lowercased())
        // The controls the turn takes change and save the prompt's record.
        started.ticket?.persister = persister
        await persister.recordPrompt(content)
        // The turn's exchange, watched for the error a failure turns out to be.
        let errors = TurnErrorWatch()
        let trimmedModel = sessionOptions?.model?.javaScriptTrimmed
        let requestedModel = trimmedModel?.isEmpty == false ? trimmedModel : nil
        let turn = Turn(
            id: control.id, recordId: recordId, agentCommand: agentCommand, cwd: cwd, mcpServers: mcpServers,
            blocks: content, model: requestedModel,
            sessionOptions: SessionAcpxState.SessionOptions(turnModel: requestedModel, sessionOptions),
            permissions: permissions,
            terminalOutputCeiling: ceiling, timeoutMilliseconds: timeout, promptRetries: retries,
            persister: persister, eventBuffer: eventBuffer, streamWire: streamWire, errors: errors, direct: direct,
            ticket: started.ticket, capabilities: fs.map { .acpx(fs: $0) }, authPolicy: authPolicy,
            callerConfig: callerConfig, stderr: stderrRelay(for: recordId, verbose: verbose),
            environment: direct ? environment : owners[recordId]?.environment)
        return try await runAttempts(turn, wasHeld: wasHeld, ownedAt: ownedAt)
    }

    /// The turn's attempts, as acpx runs the prompt its turn owns (`runOwnedSessionPrompt`): the
    /// prompt, and what the agent said of it, kept however the turn ends; a direct turn's agent
    /// let go with it; and for a caller under `--verbose`, what the agent writes to stderr sent to
    /// it with acpx's own lines, the turn's total last (`prompt.total`, from `ownedAt`).
    private func runAttempts(_ turn: Turn, wasHeld: Bool, ownedAt: ContinuousClock.Instant) async throws -> String {
        let (recordId, direct, persister) = (turn.recordId, turn.direct, turn.persister)
        return try await relayingStderr(turn.stderr, logger: recordId) {
            try await timingTotal(turn.stderr, from: ownedAt) {
                try await lettingDirectAgentGo(direct, recordId) {
                    try await reportingFailure(of: recordId, errors: turn.errors, saving: persister, direct: direct) {
                        try await beginTurn(on: persister, recordId: recordId)
                        return try await attemptWithRetry(turn, wasHeld: wasHeld)
                    }
                }
            }
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
        /// The turn's own session options, its model among them: acpx's task `sessionOptions`.
        let sessionOptions: SessionAcpxState.SessionOptions?
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
        /// A flow's persistent turn, as acpx's `sendSessionDirect` runs it: the session
        /// taken back as itself or not at all, and its agent let go when the turn ends.
        let direct: Bool
        /// The controls the turn takes as it runs: a queued turn's ticket. A direct turn has
        /// none, and leaves the ticket of a prompt queued behind it alone (#229 review).
        let ticket: PromptControlTicket?
        /// What an agent the turn connects is offered; `nil`, what the session was made with.
        let capabilities: SwiftACP.ClientCapabilities?
        /// How an agent the turn connects signs in; `nil`, as configured.
        let authPolicy: String?
        /// The config an agent the turn connects is started with; `nil`, the session's cwd's.
        let callerConfig: CallerConfig?
        /// Where what the agent writes to stderr goes as the turn runs; `nil`, nowhere.
        let stderr: AgentStderrRelay?
        /// The environment an agent the turn connects starts over; `nil`, the daemon's own.
        let environment: [String: String]?
    }

    private func attemptWithRetry(_ turn: Turn, wasHeld: Bool) async throws -> String {
        do {
            return try await attemptPrompt(turn, retriesOnAFreshLaunch: wasHeld)
        } catch is RetriedOnAFreshLaunch {
            // A held agent can exit just after `ensure` found it open. When none of the
            // turn reached it (`AgentExitedBeforeTheTurn`), the turn goes to a fresh launch
            // unseen; one it did reach is never sent twice. Nor is one the agent answered at
            // all (`TurnWireFeed.agentAnswered`): the attempt decides. A session the held
            // agent dropped is no reason to go round again: acpx's owner makes no such retry,
            // and its turn fails on the agent's error (#198).
            await evict(turn.recordId)
            return try await attemptPrompt(turn, retriesOnAFreshLaunch: false)
        }
    }

    /// An attempt a fresh launch of the agent is to take over: see
    /// ``isFixedByAFreshLaunch(_:)``.
    struct RetriedOnAFreshLaunch: Error {
        let underlying: Error
    }

    /// A failure a fresh launch of the agent would not have: the held agent exited before
    /// any of the turn reached it.
    func isFixedByAFreshLaunch(_ error: Error) -> Bool {
        error is AgentExitedBeforeTheTurn
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
        let (recordId, persister, errors) = (turn.recordId, turn.persister, turn.errors)
        // Nothing an earlier attempt showed says how this one fails — not even when it
        // fails to connect at all.
        errors.reset()
        // Until this attempt's prompt goes out, a cancel waits for it.
        promptUnsent(recordId: recordId, turn: turn.id)
        let entry = try await connectForPrompt(turn)
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
            await noteAgentTurn(outcome, of: turn, after: wireFeed)
            if let failure = await permissionFailure(of: turn, on: connection, boundSessionId) { throw failure }
            let response = outcome.response
            // The controls the turn took are done before its last save, what they said part of
            // its exchange (acpx's `seal`, `onPromptFinalizing`) — those waiting for its prompt
            // too, however late the note that it went out comes.
            takePromptNote(of: turn, from: wrote)
            await sealControls(of: turn)
            await relay.end()
            let fullText = await relay.text()
            // The exchange ends with the prompt's response; the turn's end follows it.
            await wireFeed.finish()
            // Capture the token breakdown the agent reports on the response (Claude
            // Code does; acpx misses this — it only reads usage_update._meta.usage).
            if let usage = response.usage { await persister.applyResponseUsage(usage) }
            // A direct turn's agent is let go with it, as acpx closes its client.
            if turn.direct { await letGoOfDirectAgent(recordId, persister: persister) }
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
            let failure = await permissionFailure(of: turn, on: connection, boundSessionId) ?? error
            throw await failedAttempt(
                failure, of: turn, on: entry, wrote: wrote, retriesOnAFreshLaunch: retriesOnAFreshLaunch,
                relay: relay, wireFeed: wireFeed)
        }
    }
}

extension ACPXDaemonBackend {
    /// acpx's `connectForPrompt`: the turn's agent connected, and for a caller under `--verbose`
    /// how long that took (`prompt.connect_and_load`). A reconnect that has to start a new
    /// session hands it to the persister, so the turn's saves carry it on instead of writing the
    /// old session back; what the connecting put on the wire goes to the calling client first.
    /// This turn's permissions — acpx sends the mode with every prompt and the queue owner
    /// applies it to that turn — are the live agent's from before connecting on, as is its cap
    /// on terminal output. Turns are serialized per session, so no other turn can be reading
    /// them meanwhile.
    func connectForPrompt(_ turn: Turn) async throws -> Live {
        let (recordId, persister, eventBuffer, errors) = (turn.recordId, turn.persister, turn.eventBuffer, turn.errors)
        let startedAt = ContinuousClock.now
        let entry = try await ensure(
            recordId: recordId, agentCommand: turn.agentCommand, cwd: turn.cwd, mcpServers: turn.mcpServers,
            settings: CallerSettings(
                handlers: turn.permissions.handlers, terminalOutputCeiling: turn.terminalOutputCeiling,
                timeoutMilliseconds: turn.timeoutMilliseconds, sameSessionOnly: turn.direct,
                capabilities: turn.capabilities, authPolicy: turn.authPolicy, callerConfig: turn.callerConfig,
                stderr: turn.stderr, environment: turn.environment),
            requestedModel: turn.model, turnOptions: turn.sessionOptions, turnAcpx: await persister.acpx,
            onRecordChange: { await persister.adopt($0) },
            onConnectOutput: Self.forwardToClient(logger: recordId, errors: errors),
            // acpx logs the exchange that connects the agent with the turn — all of it,
            // a reconnect the agent refused too.
            onConnectWire: { _, body in eventBuffer.append(body) })
        turn.stderr?.log(PromptTimings.metric(
            "prompt.connect_and_load", milliseconds: PromptTimings.milliseconds(since: startedAt, whole: true)))
        return entry
    }

    /// acpx's `prompt.agent_turn`, for a caller under `--verbose`: how long the answered attempt
    /// took, once what the answer said has gone out — its usage line among it, which the caller
    /// writes from it.
    func noteAgentTurn(_ outcome: PromptOutcome, of turn: Turn, after wireFeed: TurnWireFeed) async {
        guard let relay = turn.stderr, let milliseconds = outcome.agentTurnMilliseconds else { return }
        await wireFeed.drain()
        relay.log(PromptTimings.metric("prompt.agent_turn", milliseconds: milliseconds))
    }

    /// Watch an attempt's exchange as it crosses the wire: for how it fails, for the
    /// calling client, and for the prompt's answer — whose arrival marks the turn
    /// answered at once, from the reader's thread, before the connection has even handed
    /// it on, as acpx's client clears its active prompt at the answer. The note that the
    /// prompt went out comes from the writer's thread; it reaches this actor as the turn
    /// goes on, and is dropped once the turn has ended — or has taken it, acting on the
    /// attempt's end before it came (``takePromptNote(of:from:)``).
    func watchTheWire(
        of entry: Live, for turn: Turn, feeding wireFeed: TurnWireFeed, result promptResult: PromptResultCapture,
        wrote: WriteMark
    ) {
        let (recordId, turnId, errors) = (turn.recordId, turn.id, turn.errors)
        let (connection, sessionId) = (entry.agent.connection, entry.session.id)
        let eventBuffer = turn.eventBuffer
        let noted = promptNoted
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
            switch delivery {
            case .writing: break
            case .failed: return wrote.unmark()
            case .written:
                // From here on no fresh launch takes the attempt over: what it held back goes
                // out, and the rest streams, as acpx's does (#198). Not before: a write that
                // fails sends the attempt to one, its messages unseen (#236 review).
                return wireFeed.promptWritten()
            }
            wrote.mark(noting: true)
            let note: @Sendable () async -> Void = {
                await self.promptWritten(
                    recordId: recordId, turn: turnId, to: connection, sessionId: sessionId, note: wrote)
            }
            Task { if let noted { await noted(recordId, note) } else { await note() } }
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
