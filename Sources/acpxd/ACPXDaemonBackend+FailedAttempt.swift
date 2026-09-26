import ACPXCore
import Foundation
import SwiftACP

// How a prompt's failed attempt ends. Split from `ACPXDaemonBackend+Prompt.swift` to keep
// that file inside the 500-line limit.
extension ACPXDaemonBackend {
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
    ///   (``wrapUp(failedAttemptOn:error:retried:recordId:persister:)``).
    func failedAttempt(
        _ error: Error, on entry: Live, wrote: WriteMark, retriesOnAFreshLaunch: Bool, relay: TurnRelay,
        wireFeed: TurnWireFeed, recordId: String, persister: TurnPersister
    ) async -> Error {
        takePromptNote(of: recordId, from: wrote)
        let failure = ACPAgentConnection.isConnectionClosed(error) && !wrote.happened
            ? AgentExitedBeforeTheTurn(underlying: error) : error
        let retrying = retriesOnAFreshLaunch && isFixedByAFreshLaunch(failure) && turns[recordId]?.retried != true
        // Before anything else waits: a control arriving meanwhile waits for the retry.
        let handedOn = retrying && !wireFeed.agentAnswered && handControlsOn(from: recordId)
        await relay.end()
        _ = await relay.text()
        let retried = retrying && !wireFeed.agentAnswered
        if handedOn, !retried { tickets[recordId]?.publish() }
        // How the agent ended, if it did, goes into the record the failure saves — once
        // it has: an agent whose connection is gone can still be running (its stdout
        // closed, say), and is ended before its pid would be kept.
        await wrapUp(failedAttemptOn: entry, error: error, retried: retried, recordId: recordId, persister: persister)
        await wireFeed.finish(showingHeld: !retried)
        return retried ? RetriedOnAFreshLaunch(underlying: failure) : failure
    }

    /// What a failed attempt leaves: its agent ended if its connection is gone — it can be
    /// running still, its stdout closed, say, and is ended before its pid would be kept —
    /// the controls the turn took done if the turn ends here, and how the agent ended in the
    /// record the failure saves.
    func wrapUp(
        failedAttemptOn entry: Live, error: Error, retried: Bool, recordId: String, persister: TurnPersister
    ) async {
        if ACPAgentConnection.endedTheConnection(error) { await entry.agent.close() }
        if !retried { await sealControls(of: recordId) }
        await persister.applyLifecycle(entry.agent.lifecycle)
    }
}

/// The held agent had exited before any of the turn reached it: its connection was
/// already closed when the prompt was sent. Nothing was seen by it, so the turn can go
/// to a fresh launch. Reads as the closed connection it is.
struct AgentExitedBeforeTheTurn: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}
