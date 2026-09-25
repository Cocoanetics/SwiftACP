import ACPXCore
import Foundation
import Logging
import SwiftACP

// A turn's prompt under acpx's `--prompt-retries`: sent again, after a pause, while it
// fails the way a passing fault does and the turn has had no effect yet — the queue
// owner's `runPromptWithRetries`. Split from `ACPXDaemonBackend+Prompt.swift` to keep
// that file inside the 500-line limit.
extension ACPXDaemonBackend {
    /// What a turn's prompt came to.
    struct PromptOutcome {
        var response: PromptResponse
        /// Whether a prompt went out: one cancelled before its first did not.
        var sent: Bool
    }

    /// Send the turn's prompt, each attempt within its `--timeout` (``sendPrompt(_:on:recordId:within:)``),
    /// and again — up to its `--prompt-retries`, after acpx's pause — while it fails the
    /// way a passing fault does, its agent is still there, and the turn has had no effect
    /// yet: acpx's `preparePromptRetry`, which counts what the connection had of the
    /// agent from the first attempt on (``PromptSideEffects``). An effect during the
    /// pause calls the retry off. A cancel of the turn ends it cancelled in place of a
    /// retry, as acpx's aborted turn does.
    ///
    /// What a failed attempt showed goes to the calling client before what follows it:
    /// its updates, then its error, which acpx's formatter shows where it came.
    func promptWithRetries(
        _ turn: Turn, on entry: Live, relay: TurnRelay, wireFeed: TurnWireFeed
    ) async throws -> PromptOutcome {
        let connection = entry.agent.connection
        let sideEffects = PromptSideEffects()
        await connection.setWireMessageObserver { sideEffects.observe($0, $1) }
        sideEffects.begin()
        let outcome: Result<PromptOutcome, Error>
        do {
            outcome = .success(try await attempts(turn, on: entry, relay: relay, wireFeed: wireFeed, sideEffects))
        } catch {
            outcome = .failure(error)
        }
        sideEffects.end()
        await connection.setWireMessageObserver(nil)
        return try outcome.get()
    }

    private func attempts(
        _ turn: Turn, on entry: Live, relay: TurnRelay, wireFeed: TurnWireFeed, _ sideEffects: PromptSideEffects
    ) async throws -> PromptOutcome {
        let recordId = turn.recordId
        let cancelled = PromptOutcome(response: PromptResponse(stopReason: .cancelled), sent: true)
        var attempt = 0
        while true {
            do {
                let (response, sent) = try await sendPrompt(
                    turn.blocks, on: entry, recordId: recordId, within: turn.timeoutMilliseconds)
                return PromptOutcome(response: response, sent: sent || attempt > 0)
            } catch {
                // The attempt's prompt is settled: a cancel from now on has none to go to,
                // and a late note of it going out is too late.
                turns[recordId]?.prompt = nil
                turns[recordId]?.answered = true
                guard attempt < turn.promptRetries, !sideEffects.any, PromptRetry.isRetryable(error),
                      await !entry.agent.connection.isClosed
                else { throw error }
                // What the attempt showed goes out first — its updates, then its error — and
                // it is no longer a turn a fresh launch could take over unseen.
                turns[recordId]?.retried = true
                await relay.handOver(showing: wireFeed.takeHeld())
                if turns[recordId]?.cancelAsked == true { return cancelled }
                let delay = PromptRetry.delayMilliseconds(afterAttempt: attempt)
                // acpx's notice goes to its queue owner's stderr, which its CLI does not show.
                let notice = PromptRetry.notice(
                    for: error, delayMilliseconds: delay, retry: attempt + 1, maxRetries: turn.promptRetries)
                retryLog.info("\(notice)")
                await pause(milliseconds: delay, recordId: recordId)
                if turns[recordId]?.cancelAsked == true { return cancelled }
                // What happened during the pause decides, as acpx looks once as it ends.
                if sideEffects.any { throw error }
                attempt += 1
                turns[recordId]?.answered = false
                turn.errors.reset()
            }
        }
    }

    /// acpx's pause before a retry, which a cancel of the turn cuts short.
    private func pause(milliseconds: Int, recordId: String) async {
        let pause = Task<Void, Never> { try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000) }
        turns[recordId]?.pause = pause
        await retryPaused?(recordId)
        await pause.value
        turns[recordId]?.pause = nil
    }
}

private let retryLog = Logger(label: "com.cocoanetics.acpx.acpxd.retry")
