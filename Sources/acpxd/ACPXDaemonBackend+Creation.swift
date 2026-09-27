import ACPXCore
import Foundation
import SwiftACP

// The sessions a flow makes, from their creation to their hold: a session the agent gives an
// id acpxd holds already, and what a creation's call-off finds (#219 review). Split from
// `ACPXDaemonBackend.swift` and `ACPXDaemonBackend+Cancel.swift` to keep each inside the
// 500-line limit.
extension ACPXDaemonBackend {
    /// The session a flow made, its agent held for its first turn — and let go at once if it
    /// was called off as it was made, its call cancelled or its token called off first, as
    /// acpx's runner closes a client made after its attempt stopped: nobody would ever take
    /// it, or let it go.
    func keepMadeSession(
        _ held: SessionEngine.HeldSession, sessionSpecs: [MCPServerSpec]?, stderr: AgentStderrRelay?, token: String?
    ) async throws -> String {
        let recordId = held.record.acpxRecordId
        try await holdAsNew(held, sessionSpecs: sessionSpecs, stderr: stderr)
        // From a task of its own, as this one's cancellation would refuse the release.
        if Task.isCancelled || creationCalledOff(token, madeAs: recordId) {
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
    /// turn saved on its way out.
    private func holdAsNew(
        _ held: SessionEngine.HeldSession, sessionSpecs: [MCPServerSpec]?, stderr: AgentStderrRelay?
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
        return try await releaseSession(sessionId: made.recordId)
    }

    /// Whether the creation under `token` was called off before its session was made; if not,
    /// the session is kept by the token, for a call-off yet to come. Tokens kept a minute go
    /// first, so a long-lived daemon keeps only those of the last minute's creations.
    func creationCalledOff(_ token: String?, madeAs recordId: String, now: Date = Date()) -> Bool {
        guard let token else { return false }
        pruneCreationTokens(now: now)
        if calledOffCreations.removeValue(forKey: token) != nil { return true }
        madeCreations[token] = (recordId, now)
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
