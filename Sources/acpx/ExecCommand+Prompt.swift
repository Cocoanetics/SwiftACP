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
        var response: PromptResponse
        var permissions: PermissionStats
    }

    /// How `exec` sends its prompt: acpx's `--timeout` for each attempt, its
    /// `--prompt-retries`, and whether the retry notice stays off stderr — under quiet
    /// output and `--json-strict`, as acpx's `suppressSdkConsoleErrors`.
    struct PromptPolicy {
        var timeoutMilliseconds: Int?
        var retries: Int
        var quiet: Bool

        init(timeoutMilliseconds: Int?, retries: Int, quiet: Bool) {
            self.timeoutMilliseconds = timeoutMilliseconds
            self.retries = retries
            self.quiet = quiet
        }

        init(_ flags: GlobalFlags) {
            self.init(
                timeoutMilliseconds: flags.timeoutMs, retries: flags.promptRetries ?? 0, quiet: quietOutput(flags))
        }
    }

    /// Send `prompt`, each attempt within the policy's deadline, and again — up to its
    /// retries, after acpx's pause — while it fails the way a passing fault does and the
    /// turn has had no effect yet (`preparePromptRetry`). An effect during the pause
    /// calls the retry off.
    ///
    /// Text output shows each attempt's error from the agent as it comes, after what the
    /// attempt did, the way acpx's formatter shows the error response. Such an error
    /// thrown from here is therefore shown already (``showsAgentError(_:)``).
    static func runPrompt(
        _ prompt: [ContentBlock], on session: ACPSession, policy: PromptPolicy,
        renderer: OutputRenderer, sideEffects: PromptSideEffects
    ) async throws -> PromptRun {
        let connection = session.agent.connection
        let maxRetries = policy.retries
        var permissions = PermissionStats()
        sideEffects.begin()
        defer { sideEffects.end() }
        var attempt = 0
        while true {
            renderer.promptAttemptStarts()
            let events = await AttemptEvents.start(of: session, renderer: renderer, sideEffects: sideEffects)
            do {
                let response = try await withTimeout(milliseconds: policy.timeoutMilliseconds) {
                    try await session.prompt(prompt)
                }
                await events.finish()
                let last = await connection.permissionStats(for: session.id)
                permissions.add(last)
                permissions.promptUnavailable = last.promptUnavailable
                return PromptRun(response: response, permissions: permissions)
            } catch {
                // What the attempt did comes out before its failure — at a deadline too,
                // though the prompt is still out: nothing of it comes out after.
                await events.finish()
                let stats = await connection.permissionStats(for: session.id)
                permissions.add(stats)
                let agentError = error as? JSONRPCErrorBody
                if let agentError { showAgentError(RunFailure(agentError), renderer: renderer) }
                // acpx's client fails a prompt that needed a question nobody could be asked
                // with that, in place of what else failed it — and that is not retried.
                if stats.promptUnavailable, !(error is TimeoutError) { throw PromptUnavailable(agentError: agentError) }
                guard attempt < maxRetries, !sideEffects.any, PromptRetry.isRetryable(error) else { throw error }
                let delay = PromptRetry.delayMilliseconds(afterAttempt: attempt)
                // What the agent sends meanwhile is shown as it comes, as acpx's formatter
                // shows it — and calls the retry off.
                let pause = await AttemptEvents.start(of: session, renderer: renderer, sideEffects: sideEffects)
                if !policy.quiet {
                    Console.errLine(PromptRetry.notice(
                        for: error, delayMilliseconds: delay, retry: attempt + 1, maxRetries: maxRetries))
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                } catch {
                    await pause.finish()
                    throw error
                }
                // What calls the retry off has been handled — shown — before the pause's
                // events end: each update the connection has read is handed on first.
                let calledOff = sideEffects.any
                await connection.waitForSessionUpdatesHandled(sessionId: session.id)
                await pause.finish()
                guard !calledOff else { throw error }
                attempt += 1
            }
        }
    }
}

/// An attempt's events — or those of the pause before the next — rendered from a
/// subscription of its own as they come: the session's updates, the agent's requests and
/// the client's diagnostics, in wire order. Unlike
/// ``ACPSession/run(_:meta:onUpdate:onClientOperation:onInboundRequest:)``, which hands
/// them on until the prompt is over, it ends when told (``finish()``) — so a deadline can
/// end it while the prompt is still out.
private struct AttemptEvents {
    let connection: ACPAgentConnection
    let subscription: UUID
    let consumer: Task<Void, Never>

    static func start(
        of session: ACPSession, renderer: OutputRenderer, sideEffects: PromptSideEffects
    ) async -> AttemptEvents {
        let connection = session.agent.connection
        let (subscription, stream) = await connection.makeEventSubscription()
        let sessionId = session.id
        let consumer = Task {
            for await event in stream {
                switch event {
                case .update(let note) where note.sessionId == sessionId:
                    renderer.render(note.update)
                case .clientOperation(let operation)
                    where operation.sessionId == nil || operation.sessionId == sessionId:
                    sideEffects.clientOperation()
                    renderer.clientOperation(operation)
                case .inboundRequest(let request) where request.sessionId == nil || request.sessionId == sessionId:
                    renderer.inboundRequest(request)
                default:
                    break
                }
            }
        }
        return AttemptEvents(connection: connection, subscription: subscription, consumer: consumer)
    }

    /// End the subscription, and return once everything it had was rendered.
    func finish() async {
        await connection.endSubscription(subscription)
        await consumer.value
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
