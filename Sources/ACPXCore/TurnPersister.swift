import Foundation
import SwiftACP

/// Persists a session's conversation to disk *as a turn streams*, faithfully
/// porting acpx 0.11.0's `LiveSessionCheckpoint`.
///
/// Each applied update is folded into the record (via ``ConversationModel``) and
/// marks it dirty; the first dirtying schedules a debounced save one interval
/// out (500ms, like acpx's `DEFAULT_LIVE_CHECKPOINT_INTERVAL_MS`), coalescing the
/// updates that arrive in between. ``finish()`` cancels the timer, stamps the
/// activity timestamps, and writes immediately. So a long turn is checkpointed
/// roughly every 500ms — a mid-turn reader (or a crash) sees partial history,
/// just like upstream acpx.
public actor TurnPersister {
    /// acpx's `DEFAULT_LIVE_CHECKPOINT_INTERVAL_MS`.
    public static let defaultIntervalNanos: UInt64 = 500_000_000

    private var record: SessionRecord
    private let intervalNanos: UInt64
    private let eventBuffer: WireBuffer?
    private var eventWriter: SessionEventLogWriter
    private var dirty = false
    private var timer: Task<Void, Never>?

    public init(
        record: SessionRecord, eventBuffer: WireBuffer? = nil,
        intervalNanos: UInt64 = TurnPersister.defaultIntervalNanos
    ) {
        self.record = record
        self.eventBuffer = eventBuffer
        self.eventWriter = SessionEventLogWriter(record: record)
        self.intervalNanos = intervalNanos
    }

    /// Record the user's prompt as one `User` message, then schedule a save.
    public func recordPrompt(_ text: String) {
        ConversationModel.recordPromptSubmission(into: &record, prompt: text)
        request()
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
        ConversationModel.recordResponseUsage(into: &record, usage)
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
        // Drain any buffered wire lines into the event log first (this also
        // advances event_log.last_write_at / last_seq on the record), then write
        // the record if either the conversation or the event log changed.
        var changed = dirty
        if let eventBuffer {
            let lines = eventBuffer.drain()
            if !lines.isEmpty {
                eventWriter.append(lines, into: &record)
                changed = true
            }
        }
        guard changed else { return }
        dirty = false
        try? SessionStore.writeRecord(record)
    }
}
