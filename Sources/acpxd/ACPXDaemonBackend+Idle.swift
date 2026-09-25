import ACPXCore
import Foundation
import SwiftACP

// How long acpxd holds a session once its turns are over: acpx's `--ttl`. acpx's queue
// owner waits that long for its next prompt, then stops, closing its agent and writing
// how it ended to the record (`runQueueOwnerRuntime`, `closeQueueOwnerRuntime`). acpxd
// holds each session as such an owner would, and lets it go as the owner stops.
extension ACPXDaemonBackend {
    /// A session held as acpx's queue owner holds one: from the prompt that started it
    /// until it has had no prompt for its TTL. Its agent can come and go meanwhile — one
    /// closed after a prompt timed out, say — as the owner's client does.
    struct SessionOwner {
        /// acpx's `--ttl` of the prompt that started it, in milliseconds; `nil` keeps it.
        let ttlMilliseconds: Int?
        /// The wait for its next prompt, while it has none.
        var idle: Task<Void, Never>?
        /// How many turns it ran: a wait that ends looks whether one came since it began.
        var turnsRun = 0
    }

    /// acpx's `normalizeQueueOwnerTtlMs`: five minutes when not given (or negative), and
    /// `0` for no limit.
    static func ownerTTL(_ ttlMs: Int?) -> Int? {
        guard let ttlMs, ttlMs >= 0 else { return DEFAULT_TTL_MS }
        return ttlMs == 0 ? nil : ttlMs
    }

    /// A prompt's turn starts: the session's owner stops waiting for it. A session with
    /// none gets one, with the prompt's TTL; a running one keeps its own, as acpx's
    /// owner keeps the TTL it was started with.
    func turnStarts(_ recordId: String, ttlMs: Int?) {
        var owner = owners[recordId] ?? SessionOwner(ttlMilliseconds: Self.ownerTTL(ttlMs))
        owner.idle?.cancel()
        owner.idle = nil
        owner.turnsRun += 1
        owners[recordId] = owner
    }

    /// A prompt's turn is over: unless another has started, the owner waits its TTL for
    /// the next (`nextTask`).
    func turnEnded(_ recordId: String) {
        guard turns[recordId] == nil else { return }
        waitForTheNextPrompt(recordId)
    }

    /// The owner waits its TTL for its next prompt — none without a TTL.
    private func waitForTheNextPrompt(_ recordId: String) {
        guard var owner = owners[recordId], owner.idle == nil, let ttl = owner.ttlMilliseconds else { return }
        let seen = owner.turnsRun
        owner.idle = Task { [weak self] in
            guard (try? await Task.sleep(nanoseconds: UInt64(ttl) * 1_000_000)) != nil else { return }
            await self?.idleRanOut(recordId, turnsRun: seen)
        }
        owners[recordId] = owner
    }

    /// The owner's TTL ran out with no prompt since `turnsRun`. A control running then
    /// keeps it: once the control is over, it waits a full TTL again, as acpx's owner
    /// drains pending controls before it looks again (`keepOwnerForPendingControls`).
    /// Otherwise it stops.
    private func idleRanOut(_ recordId: String, turnsRun seen: Int) async {
        guard var owner = owners[recordId], owner.turnsRun == seen else { return }
        owner.idle = nil
        owners[recordId] = owner
        if await turnQueue.isBusy(recordId) {
            // A turn waits again once it is over.
            guard turns[recordId] == nil else { return }
            guard (try? await turnQueue.acquire(recordId, wait: true)) != nil else { return }
            await turnQueue.release(recordId)
            if owners[recordId]?.turnsRun == seen, turns[recordId] == nil { waitForTheNextPrompt(recordId) }
            return
        }
        await stopOwning(recordId, turnsRun: seen)
    }

    /// Stop holding the session as acpx's owner stops (`closeQueueOwnerRuntime`): its
    /// agent closed, and the record written with how the agent ended
    /// (`writeQueueOwnerLifecycleSnapshot`), read afresh — so in acpx's parser's order.
    /// Holding the session's slot, so that nothing starts meanwhile; a prompt that took
    /// it first keeps the owner.
    private func stopOwning(_ recordId: String, turnsRun seen: Int) async {
        guard (try? await turnQueue.acquire(recordId, wait: true)) != nil else { return }
        defer { Task { await turnQueue.release(recordId) } }
        guard owners[recordId]?.turnsRun == seen else { return }
        owners[recordId] = nil
        let entry = live.removeValue(forKey: recordId)
        await entry?.agent.close()
        if var record = findRecord(recordId) {
            record.applyLifecycle(entry?.agent.lifecycle)
            try? SessionStore.writeRecord(record)
        }
        await ownerStopped?(recordId)
    }

    /// The session is no longer held at all — closed, or pruned: nothing waits for it.
    func forgetOwner(_ recordId: String) {
        owners.removeValue(forKey: recordId)?.idle?.cancel()
    }
}
