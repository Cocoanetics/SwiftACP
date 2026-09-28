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
        /// The environment of the prompt that started it, which every agent it starts starts
        /// over, as acpx's queue owner starts its agent in the environment of the CLI that
        /// spawned it; `nil`, the daemon's own (#222).
        var environment: [String: String]?
        /// How many prompts may wait behind the one it runs: the `queueMaxDepth` of the prompt
        /// that started it, as acpx's owner keeps the depth it was spawned with (#240).
        var maxQueueDepth = DEFAULT_QUEUE_MAX_DEPTH
        /// What every agent it starts is offered, and how it signs in: the `--no-fs`,
        /// `--no-terminal` and `--auth-policy` of the prompt that started it, as acpx builds its
        /// owner's client from the prompt that spawned the owner (#246).
        var client = ClientOptions()
    }

    /// acpx's owner depth: `Math.max(1, Math.round(maxQueueDepth))`, 16 when not given.
    static func queueDepth(_ depth: Int?) -> Int {
        max(1, depth ?? DEFAULT_QUEUE_MAX_DEPTH)
    }

    /// acpx's `normalizeQueueOwnerTtlMs`: five minutes when not given (or negative), and
    /// `0` for no limit.
    static func ownerTTL(_ ttlMs: Int?) -> Int? {
        guard let ttlMs, ttlMs >= 0 else { return DEFAULT_TTL_MS }
        return ttlMs == 0 ? nil : ttlMs
    }

    /// A prompt's turn starts: the session's owner stops waiting for it. A session with
    /// none gets one, with the prompt's TTL, `environment` and queue depth; a running one keeps
    /// its own, as acpx's owner keeps the TTL, the environment and the depth it was started with.
    func turnStarts(
        _ recordId: String, ttlMs: Int?, environment: [String: String]? = nil, queueMaxDepth: Int? = nil,
        client: ClientOptions = ClientOptions()
    ) {
        var owner = owners[recordId]
            ?? SessionOwner(
                ttlMilliseconds: Self.ownerTTL(ttlMs), environment: environment,
                maxQueueDepth: Self.queueDepth(queueMaxDepth), client: client)
        owner.idle?.cancel()
        owner.idle = nil
        owner.turnsRun += 1
        owners[recordId] = owner
    }

    /// ``turnStarts(_:ttlMs:environment:queueMaxDepth:client:)`` with the `--ttl` and the queue
    /// depth of the prompt's `limits`.
    func turnStarts(_ recordId: String, limits: PromptLimits?, environment: [String: String]?, client: ClientOptions) {
        turnStarts(
            recordId, ttlMs: limits?.ttlMs, environment: environment, queueMaxDepth: limits?.queueMaxDepth,
            client: client)
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

    /// Whether the daemon holds nothing, as a daemon started on demand looks before it stops
    /// (``IdleExit``): no session held — by an owner, or by an agent held or being connected —
    /// no turn or control running or waiting, and no session being made or shut down.
    func holdsNothing() async -> Bool {
        guard await turnQueue.isIdle else { return false }
        return holdsNoSession
    }

    /// Stop as a daemon started on demand stops once it is idle (``IdleExit``) — unless it holds
    /// something by now: it starts no more agents (``stopping``), and gives its lock up at once,
    /// so that a CLI needing a daemon from now on starts another while this one stops. Returns
    /// whether it stopped.
    func stopIfHoldingNothing() async -> Bool {
        guard await turnQueue.isIdle, holdsNoSession else { return false }
        stopping = true
        lock?.release()
        return true
    }

    private var holdsNoSession: Bool {
        owners.isEmpty && live.isEmpty && connecting.isEmpty && turns.isEmpty && directTurns.isEmpty
            && promptLines.isEmpty && creatingTokens.isEmpty && shuttingDown.isEmpty
    }
}
