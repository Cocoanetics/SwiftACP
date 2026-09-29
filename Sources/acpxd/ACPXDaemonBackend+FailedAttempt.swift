import ACPXCore
import Foundation
import SwiftACP
import SwiftMCP

// How a prompt fails: how the calling client hears of it, and how its failed attempt
// ends. Split from `ACPXDaemonBackend+Prompt.swift` to keep that file inside the 500-line
// limit.
extension ACPXDaemonBackend {
    /// Run `body`; when it fails, save the turn so far and end its journal with the
    /// failure, then tell the calling client how, the way acpx's queue owner tells its
    /// CLI — a ``TurnFailedEvent`` — and rethrow. A journal that cannot be ended fails
    /// the turn in its place, as acpx's does. A `direct` turn's failure is told as acpx's
    /// direct turn throws it (``TurnFailure/event(for:shown:sessionId:direct:)``).
    func reportingFailure<T>(
        of recordId: String, errors: TurnErrorWatch, saving persister: TurnPersister? = nil, direct: Bool = false,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch {
            await persister?.finish()
            var failure = error
            if let unwritten = await persister?.endTurn(TurnFailure.journalResult(for: error)) { failure = unwritten }
            let event = TurnFailure.event(
                for: failure, shown: errors.match(failure), sessionId: recordId, direct: direct)
            await Self.caller?.sendLogNotification(
                LogMessage(level: .info, logger: recordId, data: toJSONValue(event)))
            throw failure
        }
    }

    /// A turn that fails before its attempt — refused, or timed out waiting for the session —
    /// told to the client as acpx's owner tells it: the turn's error.
    func failedBeforeItsAttempt(_ error: Error, of recordId: String, direct: Bool) async throws -> String {
        try await reportingFailure(of: recordId, errors: TurnErrorWatch(), direct: direct) { throw error }
    }

    /// What a direct turn fails with when it needed a permission question nobody could be
    /// asked: acpx's client then fails its prompt with that, however the prompt ended
    /// (`throwPromptPermissionFailureIfPresent`). `nil` otherwise, and for a queued turn,
    /// which tells its caller instead.
    func permissionFailure(of turn: Turn, on connection: ACPAgentConnection, _ sessionId: SessionId) async -> Error? {
        guard turn.direct, await connection.permissionStats(for: sessionId).promptUnavailable else { return nil }
        return PermissionPromptUnavailableError()
    }

    /// `body`, and for a direct turn it fails, the session's agent let go, as acpx's direct turn
    /// closes the client it was handed however it ends — one that failed before its attempt too,
    /// as a journal that cannot be opened ends it (#219 review). Where the turn let it go itself,
    /// nothing is left to; a queued turn's owner keeps its agent.
    func lettingDirectAgentGo<T>(_ direct: Bool, _ recordId: String, _ body: () async throws -> T) async throws -> T {
        guard direct else { return try await body() }
        do {
            return try await body()
        } catch {
            await Task { await self.evict(recordId) }.value
            throw error
        }
    }

    /// Let a direct turn's agent go, as acpx closes its client: once the turn's messages are
    /// written (`savePromptSuccess`, or a failed turn's own flush), which gives the agent a
    /// moment before its stdin ends.
    func letGoOfDirectAgent(_ recordId: String, persister: TurnPersister) async {
        await persister.checkpoint()
        await evict(recordId)
    }

    /// What a failed attempt leaves, and the error its turn goes on with:
    /// - the note that its prompt went out is taken first, should it not have come
    ///   (``takePromptNote(of:from:)``): coming later, it would publish the controls
    ///   handed on below;
    /// - everything the agent said before failing still goes out, and is kept, as acpx
    ///   shows and records it — then the error itself;
    /// - a failure a fresh launch takes over (``isFixedByAFreshLaunch(_:)``) is
    ///   ``RetriedOnAFreshLaunch``. The turn's controls wait for the retry's prompt from
    ///   then on, to run on its agent: none runs on the agent given up meanwhile, as the
    ///   prompt they run beside is the retry's (Codex review on #174);
    /// - how the agent ended goes into the record the failure saves
    ///   (``wrapUp(failedAttemptOn:error:retried:of:)``).
    func failedAttempt(
        _ error: Error, of turn: Turn, on entry: Live, wrote: WriteMark, retriesOnAFreshLaunch: Bool,
        relay: TurnRelay, wireFeed: TurnWireFeed
    ) async -> Error {
        takePromptNote(of: turn, from: wrote)
        let failure = ACPAgentConnection.isConnectionClosed(error) && !wrote.happened
            ? AgentExitedBeforeTheTurn(underlying: error) : error
        let retrying = retriesOnAFreshLaunch && isFixedByAFreshLaunch(failure)
            && turnControl(turn.recordId, turn.id)?.retried != true
        // Before anything else waits: a control arriving meanwhile waits for the retry.
        let handedOn = retrying && !wireFeed.agentAnswered && handControlsOn(from: turn)
        await relay.end()
        _ = await relay.text()
        let retried = retrying && !wireFeed.agentAnswered
        if handedOn, !retried { turn.ticket?.publish() }
        if !retried, let relay = turn.stderr { noteDisconnect(of: entry, to: relay) }
        // How the agent ended, if it did, goes into the record the failure saves — once
        // it has: an agent whose connection is gone can still be running (its stdout
        // closed, say), and is ended before its pid would be kept.
        await wrapUp(failedAttemptOn: entry, error: error, retried: retried, of: turn)
        await wireFeed.finish(showingHeld: !retried)
        return retried ? RetriedOnAFreshLaunch(underlying: failure) : failure
    }

    /// acpx's `emitPromptDisconnectNotice`, for a caller under `--verbose`: an agent that went
    /// while its prompt was out, which failed the turn — before the agent is let go.
    func noteDisconnect(of entry: Live, to relay: AgentStderrRelay) {
        guard let exit = entry.agent.lifecycle?.lastExit, exit.unexpectedDuringPrompt else { return }
        let code = exit.exitCode.map { String($0) } ?? "null"
        relay.log(
            "agent disconnected during prompt (\(exit.reason.rawValue), exit=\(code), signal=\(exit.signal ?? "none"))")
    }

    /// What a failed attempt leaves: its agent ended if its connection is gone — it can be
    /// running still, its stdout closed, say, and is ended before its pid would be kept —
    /// the controls the turn took done if the turn ends here, and how the agent ended in the
    /// record the failure saves.
    /// A direct turn's agent is let go however the attempt failed, as acpx closes its client.
    func wrapUp(failedAttemptOn entry: Live, error: Error, retried: Bool, of turn: Turn) async {
        if turn.direct {
            await letGoOfDirectAgent(turn.recordId, persister: turn.persister)
            try? await entry.agent.close()
        } else if ACPAgentConnection.endedTheConnection(error) {
            try? await entry.agent.close()
        }
        if !retried { await sealControls(of: turn) }
        await turn.persister.applyLifecycle(entry.agent.lifecycle)
    }
}

/// The held agent had exited before any of the turn reached it: its connection was
/// already closed when the prompt was sent. Nothing was seen by it, so the turn can go
/// to a fresh launch. Reads as the closed connection it is.
struct AgentExitedBeforeTheTurn: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}
