import ACPXCore
import Foundation
import SwiftACP

// Closing a session as acpx's owner closes one, once drained. Split from
// `ACPXDaemonBackend.swift` to keep that file inside the 500-line limit.
extension ACPXDaemonBackend {
    /// Close a session: terminate its live agent (if held) and mark the record
    /// closed — mirrors the CLI's `sessions close`.
    ///
    /// acpx's owner closes a session once drained (`closeActiveBackendSession` after
    /// `shutdown.drain()`): a prompt running is cancelled, and the turn or control holding
    /// the session gets 750 ms to be over (`QUEUE_OWNER_ACTIVE_TURN_CANCEL_GRACE_MS`).
    /// Past that, its agent is closed under it — one still connecting too, as acpx's owner
    /// closes its client connecting or not — and the close waits for it to end all the
    /// same, in its place in line, as acpx's drain waits once it has closed its client:
    /// whatever it writes comes before the close, not over it. A close called off while it
    /// waits — its caller gone — ends there, throwing `CancellationError`: nothing more is
    /// forced down, and the session is not marked closed.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    /// - Returns: `false` if no such session exists.
    func closeSession(sessionId: String) async throws -> Bool {
        guard let initial = findRecord(sessionId) else { return false }
        let recordId = initial.acpxRecordId
        _ = try? await cancelSession(sessionId: recordId)
        try await takeSessionSlot(recordId, forcingAfter: Self.closeGraceMilliseconds)
        defer { Task { await turnQueue.release(recordId) } }
        forgetOwner(recordId)
        await evict(recordId)
        // Re-read after the await: closing the agent suspends this actor, so another
        // tool (e.g. `setSessionMcpServers`, which the conflict message sends callers
        // here to unblock) may have persisted changes meanwhile. Writing the
        // pre-suspension snapshot would silently revert them.
        var record = findRecord(initial.acpxRecordId) ?? initial
        record.pid = nil
        record.closed = true
        record.closedAt = nowISO()
        try SessionStore.writeRecord(record)
        return true
    }

    /// How long a close waits for the turn or control that holds the session
    /// (`QUEUE_OWNER_ACTIVE_TURN_CANCEL_GRACE_MS`).
    static let closeGraceMilliseconds = 750

    /// Take the session's slot for a close, as acpx's owner drains before it closes: in
    /// line with the rest. Should what holds the session not be over within
    /// `milliseconds`, its agent is put down under it — one still connecting too — while
    /// the close keeps its place in line. A close called off while it waits — its caller
    /// gone — throws, forcing nothing more.
    private func takeSessionSlot(_ recordId: String, forcingAfter milliseconds: Int) async throws {
        let queue = turnQueue
        let slot = Task { try await queue.acquire(recordId, wait: true) }
        do {
            try await withTaskCancellationHandler {
                do {
                    // The deadline ends the wait for the slot's task, not the task itself.
                    try await withTimeout(milliseconds: milliseconds) { try await slot.value }
                } catch is TimeoutError {
                    await putDown(recordId)
                    try await slot.value
                }
            } onCancel: {
                slot.cancel()
            }
        } catch {
            slot.cancel()
            if (try? await slot.value) != nil { await queue.release(recordId) }
            throw error
        }
    }

    /// What holds `recordId`, put down under it: its agent held, or one still connecting.
    func putDown(_ recordId: String) async {
        await connecting[recordId]?.abandon()
        await evict(recordId)
    }
}
