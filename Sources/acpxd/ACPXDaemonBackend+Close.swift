import ACPXCore
import Foundation
import Logging
import SwiftACP

// Closing a session as acpx's owner closes one, once drained. Split from
// `ACPXDaemonBackend.swift` to keep that file inside the 500-line limit.
extension ACPXDaemonBackend {
    /// Close a session: terminate its live agent (if held) and mark the record
    /// closed — mirrors the CLI's `sessions close`.
    ///
    /// acpx's owner closes a session once drained (`closeActiveBackendSession` after
    /// `shutdown.drain()`): a prompt running is cancelled, those waiting in line behind it are
    /// refused, none of them sent, and so is any sent until the close is over
    /// (`beginShutdown`); the turn or control holding the session gets 750 ms to be over
    /// (`QUEUE_OWNER_ACTIVE_TURN_CANCEL_GRACE_MS`).
    /// Past that, its agent is closed under it — one still connecting too, as acpx's owner
    /// closes its client connecting or not — and the close waits for it to end all the
    /// same, in its place in line, as acpx's drain waits once it has closed its client:
    /// whatever it writes comes before the close, not over it. A close called off while it
    /// waits — its caller gone — ends there, throwing `CancellationError`: nothing more is
    /// forced down, and the session is not marked closed. One called off before it began
    /// does nothing at all, and cancels no prompt.
    ///
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    /// - Returns: `false` if no such session exists.
    func closeSession(sessionId: String) async throws -> Bool {
        guard let initial = findRecord(sessionId) else { return false }
        let recordId = initial.acpxRecordId
        // Called off before it began, it does nothing at all: not even the prompt running is cancelled.
        try Task.checkCancellation()
        return try await whileShuttingDown(recordId) {
            await cancelEveryTurn(recordId)
            try await takeSessionSlot(recordId, forcingAfter: Self.closeGraceMilliseconds)
            defer { Task { await turnQueue.release(recordId) } }
            await askToClose(recordId)
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
    }

    /// Let go of the session's live agent without closing the session, for `sessions new`
    /// when the agent gave the new session the replaced one's id (openclaw/acpx#805): the
    /// prompt running cancelled, the owner retired and its agent ended, as
    /// ``closeSession(sessionId:)`` does — but no `session/close`, which could end the new
    /// session under the same id, and the record, now the new session's, left as it is.
    /// Returns whether the daemon had anything of the session's: an agent held or still
    /// connecting, a turn, or an owner.
    ///
    /// Given the `turnToken` its caller gave a turn, only the agent that turn connects or runs
    /// on is put down, and only while the turn has the session's slot, as acpx's flow runner
    /// closes the client its stopped turn was handed: a turn that has ended, or not begun,
    /// leaves the session as it is, for what came since (#219 review).
    func releaseSession(sessionId: String, turnToken: String? = nil) async throws -> Bool {
        guard let initial = findRecord(sessionId) else { return false }
        let recordId = initial.acpxRecordId
        if let turnToken {
            guard let turn = directTurn(recordId, token: turnToken), turn.running else { return false }
            await putDown(recordId)
            return true
        }
        try Task.checkCancellation()
        let held = live[recordId] != nil || connecting[recordId] != nil || hasTurn(recordId) || owners[recordId] != nil
        return try await whileShuttingDown(recordId) {
            await cancelEveryTurn(recordId)
            try await takeSessionSlot(recordId, forcingAfter: Self.closeGraceMilliseconds)
            defer { Task { await turnQueue.release(recordId) } }
            forgetOwner(recordId)
            await evict(recordId)
            return held
        }
    }

    /// Let every held agent go the way acpx's queue owner does when it stops
    /// (`writeQueueOwnerLifecycleSnapshot`): each agent is closed, and how it ended goes
    /// into its record, best effort — no pid, and the connection it was closed on unless
    /// it had ended before.
    func releaseAll() async {
        // Before anything is let go: a turn whose agent this closes must not start another.
        stopping = true
        // The prompts still in line are refused, as each owner acpx stops refuses its own.
        for recordId in promptLines.keys { refusePromptsWaiting(recordId) }
        for recordId in owners.keys { forgetOwner(recordId) }
        while let recordId = live.keys.first {
            guard let entry = live.removeValue(forKey: recordId) else { continue }
            try? await entry.agent.close()
            // A turn the close ends saves its record first.
            guard (try? await turnQueue.acquire(recordId, wait: true)) != nil else { continue }
            defer { Task { await turnQueue.release(recordId) } }
            guard var record = findRecord(recordId) else { continue }
            record.applyLifecycle(entry.agent.lifecycle)
            try? SessionStore.writeRecord(record)
        }
    }

    /// Ask the agent that the session's owner holds to close the session, when it
    /// advertises it can, as acpx's owner does once drained (`closeActiveBackendSession`):
    /// best effort, as acpx's close goes on whatever comes of it.
    private func askToClose(_ recordId: String) async {
        guard owners[recordId] != nil, let entry = live[recordId],
              entry.agent.agentCapabilities?.sessionCapabilities?.supportsClose == true,
              await !entry.agent.connection.isClosed
        else { return }
        do {
            try await entry.agent.connection.closeSession(CloseSessionRequest(sessionId: entry.session.id))
        } catch {
            closeLog.info("the agent did not close session \(recordId): \(error)")
        }
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
                // A free slot is had at once, however the close was called off: once called off,
                // it gives the slot back.
                try Task.checkCancellation()
            } onCancel: {
                slot.cancel()
            }
        } catch {
            slot.cancel()
            if (try? await slot.value) != nil { await queue.release(recordId) }
            throw error
        }
    }

    /// For tests: run once a put-down has abandoned the agent it found connecting, before it
    /// lets go of the one it found held.
    @TaskLocal static var afterAbandoning: (@Sendable (_ recordId: String) async -> Void)?

    /// What holds a session at a given moment: its agent held, and one still connecting.
    struct Holding: Sendable {
        let agent: ACPAgent?
        let connecting: ConnectingAgent?
    }

    /// What holds `recordId` as this is called.
    func holding(_ recordId: String) -> Holding {
        Holding(agent: live[recordId]?.agent, connecting: connecting[recordId])
    }

    /// What holds `recordId`, put down under it: its agent held, or one still connecting.
    func putDown(_ recordId: String) async {
        await putDown(recordId, holding(recordId))
    }

    /// What held `recordId` at a given moment, put down under it — the agent then held, or the
    /// one then connecting — and nothing else, though putting it down suspends: the turn on it
    /// can end meanwhile, and a session made since under the same id can be held by then
    /// (#219 review).
    func putDown(_ recordId: String, _ holding: Holding) async {
        let launched = await holding.connecting?.abandon()
        await Self.afterAbandoning?(recordId)
        guard let agent = live[recordId]?.agent, agent === holding.agent || agent === launched else { return }
        await evict(recordId)
    }
}

private let closeLog = Logger(label: "com.cocoanetics.acpx.acpxd.close")
