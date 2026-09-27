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
        _ held: SessionEngine.HeldSession, sessionSpecs: [MCPServerSpec]?, stderr: AgentStderrRelay?, token: String?
    ) async throws -> String {
        let recordId = held.record.acpxRecordId
        try await holdAsNew(held, sessionSpecs: sessionSpecs, stderr: stderr, token: token)
        // Called off as it was held: from a task of its own, as this one's cancellation would
        // refuse the release.
        if Task.isCancelled || creationCalledOff(token, madeAs: recordId, agent: held.agent) {
            await Task { _ = try? await self.releaseSession(sessionId: recordId) }.value
            throw CancellationError()
        }
        return recordId
    }

    /// Hold a new session's agent. One acpxd holds under the same id already — another run's,
    /// or an agent's stable id — is let go first, as `sessions new` retires a session it
    /// replaces under the same id (`SessionLifecycle.retire`): with no `session/close`, which
    /// would reach the new session too, and once whatever turn it runs is over, as that turn is
    /// nobody's to call off. The session's turn slot is held throughout, so no prompt starts an
    /// agent in between; and the new record is written once more, over whatever the old one's
    /// turn saved on its way out; the prompts meant for the old one are refused. A creation
    /// called off before it would take that place — the
    /// slot had, or while it waited for it — takes nobody's place: its own agent goes, and the
    /// session held under the id stays as it is (#219 review).
    private func holdAsNew(
        _ held: SessionEngine.HeldSession, sessionSpecs: [MCPServerSpec]?, stderr: AgentStderrRelay?, token: String?
    ) async throws {
        let recordId = held.record.acpxRecordId
        let taken = live[recordId] != nil || connecting[recordId] != nil || turns[recordId] != nil
            || owners[recordId] != nil
        guard taken else {
            _ = try await hold(held.agent, on: held.session, sessionSpecs: sessionSpecs, for: recordId, via: nil,
                               stderr: stderr)
            return
        }
        do {
            try await turnQueue.acquire(recordId, wait: true)
        } catch {
            await held.agent.close()
            throw error
        }
        guard !isCalledOff(token) else {
            await turnQueue.release(recordId)
            await held.agent.close()
            throw CancellationError()
        }
        // The prompts meant for the session it replaces are refused, as `sessions new` refuses
        // those in line as it lets a session go: those still in line, and one begun as the turn
        // before it ended, yet to have the slot — none runs on the new agent (#219 review).
        refusePromptsWaiting(recordId)
        turns[recordId]?.refused = true
        let outcome: Result<Void, Error>
        do {
            forgetOwner(recordId)
            await evict(recordId)
            try SessionStore.writeRecord(held.record)
            _ = try await hold(held.agent, on: held.session, sessionSpecs: sessionSpecs, for: recordId, via: nil,
                               stderr: stderr)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await turnQueue.release(recordId)
        if case .failure(let error) = outcome {
            await held.agent.close()
            throw error
        }
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
        return await releaseMade(made)
    }

    /// Let go of the agent the creation under a token made, when it is still the one held for
    /// its session and nothing has it: not one that took its place under the same id since,
    /// nor one a turn or an owner now has, which let it go themselves (#219 review).
    private func releaseMade(_ made: MadeCreation) async -> Bool {
        let recordId = made.recordId
        guard let entry = live[recordId], entry.agent === made.agent, turns[recordId] == nil,
              owners[recordId] == nil else { return false }
        live.removeValue(forKey: recordId)
        await entry.agent.close()
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

    /// Let go of the creation tokens kept a minute (#219 review): by then a caller whose wait
    /// was cut short has called its creation off. A call-off of a creation still under way is
    /// kept until the creation is over, however long its agent takes.
    private func pruneCreationTokens(now: Date) {
        calledOffCreations = calledOffCreations.filter {
            creatingTokens.contains($0.key) || now.timeIntervalSince($0.value) < 60
        }
        madeCreations = madeCreations.filter { now.timeIntervalSince($0.value.at) < 60 }
    }
}
