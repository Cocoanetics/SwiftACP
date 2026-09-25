import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

// `exec`'s prompt: each attempt within `--timeout`, and another attempt under
// `--prompt-retries`, as acpx's `runExecPromptWithRetries` goes about it. Split from
// `ExecCommand.swift` to keep each file inside the 500-line limit.
extension ExecCommand {
    /// What the prompt came to: the last attempt's outcome, with the permission counts
    /// of every attempt — acpx's client counts across its run — and whether that last
    /// attempt needed a permission question nobody could be asked (acpx drops that with
    /// an attempt that fails).
    struct PromptRun {
        var outcome: PromptOutcome
        var permissions: PermissionStats
    }

    /// Send `prompt`, each attempt within `flags.timeoutMs`, and again — up to
    /// `flags.promptRetries` times, after acpx's pause — while it fails the way a passing
    /// fault does and the turn has had no effect yet (`preparePromptRetry`). An effect
    /// during the pause calls the retry off.
    ///
    /// Text output shows each attempt's error from the agent as it comes, after what the
    /// attempt did, the way acpx's formatter shows the error response. Such an error
    /// thrown from here is therefore shown already (``showsAgentError(_:)``).
    static func runPrompt(
        _ prompt: [ContentBlock], on session: ACPSession, flags: GlobalFlags,
        renderer: OutputRenderer, sideEffects: PromptSideEffects
    ) async throws -> PromptRun {
        let connection = session.agent.connection
        let maxRetries = flags.promptRetries ?? 0
        var permissions = PermissionStats()
        sideEffects.begin()
        defer { sideEffects.end() }
        var attempt = 0
        while true {
            renderer.promptAttemptStarts()
            do {
                let outcome = try await withTimeout(milliseconds: flags.timeoutMs) {
                    try await session.run(
                        prompt, onUpdate: { renderer.render($0) },
                        onClientOperation: {
                            sideEffects.clientOperation()
                            renderer.clientOperation($0)
                        },
                        onInboundRequest: { renderer.inboundRequest($0) })
                }
                let last = await connection.permissionStats(for: session.id)
                permissions.add(last)
                permissions.promptUnavailable = last.promptUnavailable
                return PromptRun(outcome: outcome, permissions: permissions)
            } catch {
                let stats = await connection.permissionStats(for: session.id)
                permissions.add(stats)
                let agentError = error as? JSONRPCErrorBody
                if let agentError { showAgentError(RunFailure(agentError), renderer: renderer) }
                // acpx's client fails a prompt that needed a question nobody could be asked
                // with that, in place of what else failed it — and that is not retried.
                if stats.promptUnavailable, !(error is TimeoutError) { throw PromptUnavailable(agentError: agentError) }
                guard attempt < maxRetries, !sideEffects.any, PromptRetry.isRetryable(error) else { throw error }
                let delay = PromptRetry.delayMilliseconds(afterAttempt: attempt)
                if !quietOutput(flags) {
                    Console.errLine(PromptRetry.notice(
                        for: error, delayMilliseconds: delay, retry: attempt + 1, maxRetries: maxRetries))
                }
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                guard !sideEffects.any else { throw error }
                attempt += 1
            }
        }
    }
}

extension PermissionStats {
    /// Count `other`'s decisions in too, as acpx's client counts every attempt's.
    mutating func add(_ other: PermissionStats) {
        requested += other.requested
        approved += other.approved
        denied += other.denied
        cancelled += other.cancelled
    }
}
