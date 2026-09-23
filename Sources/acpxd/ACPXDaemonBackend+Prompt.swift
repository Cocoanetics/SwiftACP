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
    ///   - wait: when another turn is already running for this session, `true` (the
    ///     default) queues this one behind it; `false` rejects it immediately with a
    ///     "session busy" error instead of waiting.
    ///   - permissionMode: how this turn's permission requests and writes are
    ///     answered — see ``TurnPermissions``. `nil` approves everything.
    ///   - nonInteractivePermissions: `deny` (the default) or `fail`.
    /// - Returns: the agent's aggregate response text for the turn. The turn's stop
    ///   reason is streamed separately as a final ``TurnEndedEvent`` log
    ///   notification (sent after the last `session/update`, before this returns).
    func runPrompt(
        sessionId rawSessionId: String, text: String,
        blocks: [PromptBlock]? = nil, wait: Bool = true,
        permissionMode: String? = nil, nonInteractivePermissions: String? = nil
    ) async throws -> String {
        let sessionId = rawSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { throw DaemonError.emptySessionId }
        // Checked before queueing, like the blocks: a bad mode is the caller's mistake,
        // not something to find out after waiting out another turn.
        let permissions = try TurnPermissions(
            mode: permissionMode, nonInteractive: nonInteractivePermissions)
        // Validate before queueing: a malformed block should fail at once, not after
        // waiting out someone else's turn. The daemon's transport has a ceiling, so
        // the request size is capped here (a direct client has nothing in the way).
        let content = try PromptBlock.contentBlocks(
            text: text, blocks: blocks, requestLimit: PromptBlock.maxRequestBytes)
        guard let initial = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let acpSessionId = initial.acpSessionId

        // One turn per session at a time: queue behind any in-flight turn (or, when
        // wait == false, reject), so concurrent CLI/MCP callers never drive one
        // agent — or persist one record — concurrently. Keyed by ACP session id.
        try await turnQueue.acquire(acpSessionId, wait: wait)
        // `defer` can't await; the hop to the queue actor is safe because release
        // hands the slot to the next FIFO waiter regardless of when it lands.
        defer { Task { await turnQueue.release(acpSessionId) } }

        // Reload the record *after* acquiring the slot: a turn we queued behind has
        // just persisted new history, and the persister must build on that, not on a
        // stale pre-wait snapshot (whose final flush would otherwise clobber it).
        guard let record = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let agentCommand = record.agentCommand
        let cwd = record.cwd
        let mcpServers = record.acpx?.mcpServers
        // Whether this turn starts on a connection the daemon already holds — the only
        // case in which a session-gone failure can mean the agent dropped the session
        // from under it (see the retry below).
        let wasHeld = live[acpSessionId] != nil
        // Gate each block on what the agent advertised, the way npm acpx's client
        // does: an agent without the capability either ignores the block or errors
        // opaquely. Capabilities come from `initialize`, so this has to connect first
        // — `ensure` is idempotent, and the turn below reuses the entry it warms.
        // Refusing *here*, before the prompt is recorded, keeps a turn the agent
        // never saw out of the session's history. Text and `resource_link` are never
        // gated, so an ordinary turn still connects lazily.
        let gated = content.enumerated().compactMap { index, block in
            block.requiredPromptCapability.map { (index: index, requirement: $0) }
        }
        if !gated.isEmpty {
            let entry = try await ensure(
                sessionId: acpSessionId, agentCommand: agentCommand, cwd: cwd,
                mcpServers: mcpServers)
            let capabilities = entry.agent.promptCapabilities
            if let unmet = gated.first(where: { !$0.requirement.isAdvertised(by: capabilities) }) {
                throw PromptBlockError.capabilityUnsupported(
                    index: unmet.index, capability: unmet.requirement.rawValue,
                    agent: agentCommand)
            }
        }
        // Record the user's prompt once, up front; the persister checkpoints the
        // turn to disk on a debounce as updates stream in (acpx's live checkpoint),
        // draining the wire buffer into the event log on each save. A session-gone
        // retry reuses both, so the prompt isn't double-recorded.
        let eventBuffer = WireBuffer()
        let persister = TurnPersister(record: record, eventBuffer: eventBuffer)
        await persister.recordPrompt(content)
        do {
            return try await attemptPrompt(
                sessionId: acpSessionId, agentCommand: agentCommand, cwd: cwd,
                mcpServers: mcpServers, blocks: content, permissions: permissions,
                persister: persister, eventBuffer: eventBuffer)
        } catch {
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
            // launch unseen; one it did reach is never sent twice.
            guard wasHeld, isSessionGone(error) || error is AgentExitedBeforeTheTurn else { throw error }
            await evict(acpSessionId)
            return try await attemptPrompt(
                sessionId: acpSessionId, agentCommand: agentCommand, cwd: cwd,
                mcpServers: mcpServers, blocks: content, permissions: permissions,
                persister: persister, eventBuffer: eventBuffer)
        }
    }

    private func attemptPrompt(
        sessionId: String, agentCommand: String, cwd: String, mcpServers: [McpServerConfig]?,
        blocks: [ContentBlock], permissions: TurnPermissions, persister: TurnPersister,
        eventBuffer: WireBuffer
    ) async throws -> String {
        let entry = try await ensure(
            sessionId: sessionId, agentCommand: agentCommand, cwd: cwd, mcpServers: mcpServers)
        let connection = entry.agent.connection
        let boundSessionId = entry.session.id
        // Whether any of this turn has been written to the agent — its prompt is the
        // first thing that is. Cleared when the turn ends.
        let wrote = WriteMark()
        entry.agent.rawWire.set { direction, _ in if direction == .outbound { wrote.mark() } }
        defer { entry.agent.rawWire.set(nil) }
        // The calling client's MCP session — stream updates to it as log notifications.
        let clientSession = Session.current

        // This turn's permissions: acpx sends the mode with every prompt and the queue
        // owner applies it to that turn, so the live agent's handlers are swapped per
        // turn rather than fixed at launch. Turns are serialized per session, so no
        // other turn can be reading them meanwhile.
        await connection.setHandlers(permissions.handlers)
        // Tee every JSON-RPC line on the wire into the buffer; the persister drains
        // it into the event log on each checkpoint. Cleared when the turn ends.
        await connection.setWireObserver { line in eventBuffer.append(line) }

        // Subscribe before prompting so no event is missed, then drain the
        // subscription deterministically: ending it (after `prompt` returns)
        // finishes the stream, so the consumer task completes having sent every
        // event — in order — and built the agent's message content for the turn.
        let (subscriptionId, stream) = await connection.makeEventSubscription()
        let consumer = Task { () -> String in
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
        do {
            let response = try await entry.session.prompt(blocks)
            await connection.endSubscription(subscriptionId)
            await connection.setWireObserver(nil)
            let fullText = await consumer.value
            // Capture the token breakdown the agent reports on the response (Claude
            // Code does; acpx misses this — it only reads usage_update._meta.usage).
            if let usage = response.usage { await persister.applyResponseUsage(usage) }
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
                        stopReason: response.stopReason.rawValue, permissions: permissionStats))))
            return fullText
        } catch {
            await connection.endSubscription(subscriptionId)
            await connection.setWireObserver(nil)
            consumer.cancel()
            if ACPAgentConnection.isConnectionClosed(error), !wrote.happened {
                throw AgentExitedBeforeTheTurn(underlying: error)
            }
            throw error
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
    init(mode: String?, nonInteractive: String?) throws {
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
            permission: policy, nonInteractivePermissions: unanswerable, terminal: .none)
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

    var happened: Bool {
        lock.withLock { marked }
    }
}
