import Foundation
import Logging
import SwiftACP

/// Persists a session's conversation to disk *as a turn streams*, faithfully
/// porting acpx 0.11.0's `LiveSessionCheckpoint`.
///
/// The prompt is saved at once (``recordPrompt(_:)-(String)``), and again once the turn
/// has connected (``checkpoint()``). Each applied update is then folded into the record
/// (via ``ConversationModel``) and marks it dirty; the first dirtying schedules a
/// debounced save one interval out (500ms, like acpx's
/// `DEFAULT_LIVE_CHECKPOINT_INTERVAL_MS`), coalescing the updates that arrive in
/// between. ``finish()`` cancels the timer, stamps the activity timestamps, and writes
/// immediately. So a long turn is checkpointed roughly every 500ms — a mid-turn reader
/// (or a crash) sees partial history, and the event log what the last save put in it,
/// just like upstream acpx.
public actor TurnPersister {
    /// acpx's `DEFAULT_LIVE_CHECKPOINT_INTERVAL_MS`.
    public static let defaultIntervalNanos: UInt64 = 500_000_000

    private var record: SessionRecord
    private let intervalNanos: UInt64
    private let eventBuffer: WireBuffer?
    /// The turn's request id: what its journal records are keyed by, and the record's
    /// `last_request_id`.
    private let requestId: String?
    /// The event log, from the turn's start (``beginTurn()``) to its end (``endTurn(_:)``).
    private var eventWriter: SessionEventLogWriter?
    /// Whether the journal has the turn's start and not yet its end.
    private var turnOpen = false
    private var dirty = false
    private var timer: Task<Void, Never>?
    /// The user message this turn started with. The response's usage is attributed to
    /// it, not to whatever user message happens to be last when the response lands — an
    /// echoed `userMessageChunk`, or the next prompt, can arrive in between (acpx's
    /// prompt turn passes the same id).
    private var promptMessageId: String?

    /// - Parameter requestId: the turn's request id, which acpx's queue owner keys the
    ///   turn's journal records with and keeps as the record's `last_request_id`.
    public init(
        record: SessionRecord, eventBuffer: WireBuffer? = nil, requestId: String? = nil,
        intervalNanos: UInt64 = TurnPersister.defaultIntervalNanos
    ) {
        self.record = record
        if let requestId { self.record.lastRequestId = requestId }
        self.eventBuffer = eventBuffer
        self.requestId = requestId
        self.intervalNanos = intervalNanos
    }

    /// Open the session's event log for the turn, as acpx's prompt does before it
    /// connects: the journal read to where it left off — one that cannot be read throws,
    /// ``SessionJournalError`` for one that is corrupt — and the turn's start written.
    /// From then on each save puts the wire's messages in the log. Failing to write the
    /// start throws ``SessionJournalWriteError``.
    public func beginTurn() throws {
        var writer = try SessionEventLogWriter.open(record: &record)
        if let requestId {
            do {
                try writer.beginTurn(requestId, into: &record)
            } catch {
                throw SessionJournalWriteError(underlying: error)
            }
            turnOpen = true
        }
        eventWriter = writer
    }

    /// acpx's `finishTurn`: the turn's result, after all the wire's messages yet to be
    /// logged — for a turn whose start the journal has, and once; nothing is logged after
    /// it. Returns why it could not be written, which acpx makes the turn's failure — a
    /// message it could not log, too.
    public func endTurn(_ result: SessionJournal.TurnResult) -> SessionJournalWriteError? {
        guard turnOpen, let requestId else { return nil }
        turnOpen = false
        flush()
        defer { eventWriter = nil }
        do {
            try eventWriter?.finishTurn(requestId, result, into: &record)
            return nil
        } catch {
            return SessionJournalWriteError(underlying: error)
        }
    }

    /// The `acpx` state of the record the turn saves, as it stands.
    public var acpx: SessionAcpxState? { record.acpx }

    /// Apply a change a reconnect made — the session it moved the record to, what that
    /// session advertises, what the replay put back — to the record the turn saves,
    /// and save it at once: any later save would otherwise write the old state back.
    public func adopt(_ change: @Sendable (inout SessionRecord) -> Void) {
        change(&record)
        dirty = true
        flush()
    }

    /// Record the user's prompt as one `User` message, and save it at once, as acpx
    /// writes the prompt's record before it runs.
    public func recordPrompt(_ text: String) {
        promptMessageId = ConversationModel.recordPromptSubmission(into: &record, prompt: text)
        checkpoint()
    }

    /// Record a structured prompt (text plus attachments) as the turn's user message.
    public func recordPrompt(_ blocks: [ContentBlock]) {
        ConversationModel.recordPromptSubmission(into: &record, prompt: blocks)
        checkpoint()
    }

    /// Save now, as acpx's `LiveSessionCheckpoint.checkpoint` does: a turn saves once
    /// connected, before its prompt goes out, with what connecting put on the wire.
    public func checkpoint() {
        timer?.cancel()
        timer = nil
        dirty = true
        flush()
    }

    /// Fold one streamed `session/update` into the conversation, then schedule a save.
    public func apply(_ update: SessionUpdate) {
        ConversationModel.recordSessionUpdate(
            into: &record,
            notification: SessionNotification(sessionId: record.acpSessionId, update: update))
        request()
    }

    /// Record the token breakdown from the prompt response (the place agents
    /// actually report it). Flushed by the following ``finish()``.
    public func applyResponseUsage(_ usage: PromptUsage) {
        ConversationModel.recordResponseUsage(
            into: &record, usage, promptMessageId: promptMessageId)
        dirty = true
    }

    /// How the agent is doing, as acpx writes it when a turn ends
    /// (`applyLifecycleSnapshotToRecord`) — saved with the next write.
    public func applyLifecycle(_ snapshot: AgentLifecycleSnapshot?) {
        record.applyLifecycle(snapshot)
        dirty = true
    }

    /// Final flush: stamp `last_used_at` / `last_prompt_at` and write immediately.
    public func finish() {
        timer?.cancel()
        timer = nil
        let now = nowISO()
        record.lastUsedAt = now
        record.lastPromptAt = now
        dirty = true
        flush()
    }

    /// Mark dirty and, if no save is already pending, schedule one an interval out.
    private func request() {
        dirty = true
        guard timer == nil else { return }
        let nanos = intervalNanos
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            await self?.fire()
        }
    }

    private func fire() {
        timer = nil
        flush()
    }

    private func flush() {
        // Drain the wire's buffered messages into the event log first, while the turn
        // has it open (this also advances event_log.last_write_at / last_seq on the
        // record), then write the record if either the conversation or the log changed.
        var changed = dirty
        if let eventBuffer, eventWriter != nil {
            let bodies = eventBuffer.drain()
            if !bodies.isEmpty {
                do {
                    try eventWriter?.append(bodies, into: &record)
                } catch {
                    // Reported with the turn's result, which it keeps from being written.
                    log.warning("session event log write failed: \(error)")
                }
                // acpx keeps the turn's request id as the record's `last_request_id`.
                if let requestId { record.lastRequestId = requestId }
                changed = true
            }
        }
        guard changed else { return }
        do {
            try SessionStore.writeRecord(record)
            dirty = false
        } catch {
            // Keep the record dirty so the next checkpoint retries the write
            // instead of silently dropping this slice of the conversation.
            log.warning("session checkpoint write failed: \(error)")
        }
    }
}

private let log = Logger(label: "com.cocoanetics.acpx.turn-persister")
