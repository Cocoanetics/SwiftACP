import ACPXCore
import Foundation
import SwiftACP

// The sessions a flow makes, from their creation to their hold: a session the agent gives an
// id acpxd holds already, and what a creation's call-off finds (#219 review). Split from
// `ACPXDaemonBackend.swift` and `ACPXDaemonBackend+Cancel.swift` to keep each inside the
// 500-line limit.
extension ACPXDaemonBackend {
    /// A session a creation made, kept by its token for a call-off yet to come: its record, and
    /// the agent held for it — the one a call-off lets go, and no other.
    struct MadeCreation: Sendable {
        let recordId: String
        let agent: any AnyObject & Sendable
        let at: Date
    }

    /// The session a flow made, its agent held for its first turn — and let go at once if it
    /// was called off as it was made, its call cancelled or its token called off first, as
    /// acpx's runner closes a client made after its attempt stopped: nobody would ever take
    /// it, or let it go.
    func keepMadeSession(
        _ held: SessionEngine.HeldSession, stderr: AgentStderrRelay?, token: String?
    ) async throws -> String {
        let recordId = held.record.acpxRecordId
        try await holdAsNew(held, stderr: stderr, token: token)
        await creationKept?(recordId)
        // Called off as it was held: its own agent goes, and none that took its place since under
        // the same id — from a task of its own, as this one's cancellation would cut the close
        // short (#219 review).
        if Task.isCancelled || creationCalledOff(token, madeAs: recordId, agent: held.agent) {
            let agent = held.agent
            await Task { _ = await self.releaseOwn(recordId, agent: agent) }.value
            throw CancellationError()
        }
        return recordId
    }

    /// Hold a new session's agent, and write its record: holding the session's turn slot, so
    /// that creations under one id — an agent that gives every session the same id — take it
    /// in turn, and no prompt starts an agent meanwhile. One acpxd holds under the id already —
    /// another run's — is let go first, as `sessions new` retires a session it replaces under
    /// the same id (`SessionLifecycle.retire`): with no `session/close`, which would reach the
    /// new session too, once whatever turn it runs is over, and with the prompts meant for it
    /// refused. A creation called off before it has the slot takes nobody's place: its own agent
    /// goes, and a session held under the id stays as it is, its record too (#219 review).
    private func holdAsNew(
        _ held: SessionEngine.HeldSession, stderr: AgentStderrRelay?, token: String?
    ) async throws {
        let recordId = held.record.acpxRecordId
        await reconnected?(recordId)
        do {
            try await turnQueue.acquire(recordId, wait: true)
        } catch {
            await held.agent.close()
            throw error
        }
        let taken = live[recordId] != nil || hasTurn(recordId) || owners[recordId] != nil
        let outcome: Result<Void, Error>
        if isCalledOff(token) {
            // Its record kept when the id is new, as acpx's creation writes it — never over the
            // record of a session on it already, held or not (#219 review).
            if !taken, SessionStore.loadRecord(recordId) == nil { try? SessionStore.writeRecord(held.record) }
            outcome = .failure(CancellationError())
        } else {
            if taken {
                // The prompts meant for the session it replaces are refused: those still in
                // line, and one begun as the turn before it ended, yet to have the slot.
                refusePromptsWaiting(recordId)
                turns[recordId]?.refused = true
                for turn in directTurns[recordId] ?? [] { changeTurn(recordId, turn.id) { $0.refused = true } }
                forgetOwner(recordId)
                await evict(recordId)
            }
            outcome = Result { try keep(held, stderr: stderr) }
        }
        await turnQueue.release(recordId)
        if case .failure(let error) = outcome {
            await held.agent.close()
            throw error
        }
    }

    /// Keep a new session: its record written, and its agent held for its first turn.
    private func keep(
        _ held: SessionEngine.HeldSession, stderr: AgentStderrRelay?
    ) throws {
        guard !stopping else { throw DaemonError.stopping }
        let recordId = held.record.acpxRecordId
        try SessionStore.writeRecord(held.record)
        live[recordId] = Live(agent: held.agent, session: held.session, stderr: stderr)
        held.agent.rawWire.set(nil)
    }

    /// Whether the creation under `token` has been called off: its call cancelled, or its token
    /// called off. The call-off stays, for ``creationCalledOff(_:madeAs:)``.
    private func isCalledOff(_ token: String?) -> Bool {
        Task.isCancelled || token.map { calledOffCreations[$0] != nil } == true
    }

    /// Call off the session a `newSession` makes under `creationToken`: one made is let go, and
    /// one not made yet is let go as it is made (``creationCalledOff(_:madeAs:)``). On the actor
    /// with no suspension until then, so either the call-off finds the session or the creation
    /// finds the call-off.
    func callOffCreation(creationToken: String) async throws -> Bool {
        let now = Date()
        pruneCreationTokens(now: now)
        guard let made = madeCreations.removeValue(forKey: creationToken) else {
            calledOffCreations[creationToken] = now
            return false
        }
        return await releaseOwn(made.recordId, agent: made.agent)
    }

    /// Let go of the agent a creation made, held for `recordId`'s session, when it still is and
    /// nothing has it: not one that took its place under the same id since, nor one a turn or an
    /// owner now has, which let it go themselves (#219 review).
    private func releaseOwn(_ recordId: String, agent: AnyObject) async -> Bool {
        guard live[recordId]?.agent === agent, !hasTurn(recordId), owners[recordId] == nil else {
            return false
        }
        await evict(recordId)
        return true
    }

    /// Whether the creation under `token` was called off before its session was made; if not,
    /// the session — by its record and the agent held for it — is kept by the token, for a
    /// call-off yet to come. Tokens kept a minute go
    /// first, so a long-lived daemon keeps only those of the last minute's creations.
    func creationCalledOff(
        _ token: String?, madeAs recordId: String, agent: any AnyObject & Sendable, now: Date = Date()
    ) -> Bool {
        guard let token else { return false }
        pruneCreationTokens(now: now)
        if calledOffCreations.removeValue(forKey: token) != nil { return true }
        madeCreations[token] = MadeCreation(recordId: recordId, agent: agent, at: now)
        return false
    }

    /// Let go of the call-offs kept a minute (#219 review): by then the creation they name has
    /// come, or never will — unless it is still under way, however long its agent takes. What a
    /// creation made is kept while its agent is the one held for its session: until that agent
    /// is let go (``evict(_:)``), or found dead, however it went.
    private func pruneCreationTokens(now: Date) {
        calledOffCreations = calledOffCreations.filter {
            creatingTokens.contains($0.key) || now.timeIntervalSince($0.value) < 60
        }
        madeCreations = madeCreations.filter { live[$0.value.recordId]?.agent === $0.value.agent }
    }
}
