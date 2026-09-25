import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

// `exec`'s prompt: each attempt within `--timeout`, and another attempt under
// `--prompt-retries`, as acpx's `runExecPromptWithRetries` goes about it. Split from
// `ExecCommand.swift` to keep each file inside the 500-line limit.
extension ExecCommand {
    /// What the prompt came to: the last attempt's outcome, with the permission counts
    /// of every attempt and of the pauses between them — acpx's client counts across its
    /// run — and whether that last attempt needed a permission question nobody could be
    /// asked (acpx drops that with an attempt that fails).
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
        let countedBefore = await connection.permissionTotals(for: session.id)
        sideEffects.begin()
        defer { sideEffects.end() }
        var attempt = 0
        var events = await PhaseEvents.subscribe(to: session)
        while true {
            renderer.promptAttemptStarts()
            events.render(with: renderer)
            do {
                let response = try await withTimeout(milliseconds: policy.timeoutMilliseconds) {
                    try await session.prompt(prompt)
                }
                await events.finish()
                let permissions = await connection.permissionTotals(for: session.id).counted(since: countedBefore)
                return PromptRun(response: response, permissions: permissions)
            } catch {
                // What the attempt did comes out before its failure — the agent's error where
                // it came in the wire (``PhaseEvents``) — and at a deadline too, though the
                // prompt is still out. An update read before the deadline can still be on its
                // way to the subscriptions, so what the connection has read is handed on
                // first. What comes after is the pause's.
                await connection.waitForSessionUpdatesHandled(sessionId: session.id)
                let pause = await events.handOver()
                await events.finish()
                let stats = await connection.permissionStats(for: session.id)
                let agentError = error as? JSONRPCErrorBody
                // The run fails here: what the agent sent since is shown too, as acpx's
                // formatter shows it until the client closes.
                func failing(_ failure: Error) async -> Error {
                    await connection.waitForSessionUpdatesHandled(sessionId: session.id)
                    pause.render(with: renderer)
                    await pause.finish()
                    return failure
                }
                // acpx's client fails a prompt that needed a question nobody could be asked
                // with that, in place of what else failed it — and that is not retried.
                if stats.promptUnavailable, !(error is TimeoutError) {
                    throw await failing(PromptUnavailable(agentError: agentError))
                }
                guard attempt < maxRetries, !sideEffects.any, PromptRetry.isRetryable(error) else {
                    throw await failing(error)
                }
                let delay = PromptRetry.delayMilliseconds(afterAttempt: attempt)
                if !policy.quiet {
                    Console.errLine(PromptRetry.notice(
                        for: error, delayMilliseconds: delay, retry: attempt + 1, maxRetries: maxRetries))
                }
                // What the agent sends meanwhile is shown as it comes, as acpx's formatter
                // shows it — and calls the retry off.
                pause.render(with: renderer)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                } catch {
                    await pause.finish()
                    throw error
                }
                // The pause ends at one point in the events, which decides, as acpx looks
                // once as its pause ends: what came before is shown, and counts; what comes
                // after is the next attempt's.
                let next = await pause.handOver()
                await pause.finish()
                if sideEffects.any {
                    // What called the retry off is handed on, and shown, before the failure.
                    await connection.waitForSessionUpdatesHandled(sessionId: session.id)
                    next.render(with: renderer)
                    await next.finish()
                    throw error
                }
                events = next
                attempt += 1
            }
        }
    }
}

/// The events of one phase of the prompt — an attempt, or the pause before the next —
/// from a subscription of its own: the session's updates, the agent's requests, the
/// client's diagnostics and the agent's error failing the prompt, in wire order, rendered
/// once told to (``render(with:)``). A phase
/// hands over to the next at one point in the events (``handOver()``), so none falls
/// between the two. Unlike ``ACPSession/run(_:meta:onUpdate:onClientOperation:onInboundRequest:)``,
/// which hands them on until the prompt is over, it ends when told (``finish()``) — so a
/// deadline can end an attempt while its prompt is still out.
private final class PhaseEvents {
    private let connection: ACPAgentConnection
    private let sessionId: SessionId
    private let subscription: UUID
    private let stream: AsyncStream<ConnectionEvent>
    private var consumer: Task<Void, Never>?

    private init(
        connection: ACPAgentConnection, sessionId: SessionId, subscription: UUID,
        stream: AsyncStream<ConnectionEvent>
    ) {
        self.connection = connection
        self.sessionId = sessionId
        self.subscription = subscription
        self.stream = stream
    }

    static func subscribe(to session: ACPSession) async -> PhaseEvents {
        let connection = session.agent.connection
        let (subscription, stream) = await connection.makeEventSubscription()
        return PhaseEvents(connection: connection, sessionId: session.id, subscription: subscription, stream: stream)
    }

    /// Render the phase's events — those that came so far, and those to come — until it
    /// ends.
    func render(with renderer: OutputRenderer) {
        let (stream, sessionId) = (stream, sessionId)
        consumer = Task {
            for await event in stream {
                await renderer.beforeRenderingEvent?()
                switch event {
                case .update(let note) where note.sessionId == sessionId:
                    renderer.render(note.update)
                case .clientOperation(let operation)
                    where operation.sessionId == nil || operation.sessionId == sessionId:
                    renderer.clientOperation(operation)
                case .inboundRequest(let request) where request.sessionId == nil || request.sessionId == sessionId:
                    renderer.inboundRequest(request)
                case .promptFailed(let failed, let error) where failed == sessionId:
                    ExecCommand.showAgentError(ExecCommand.RunFailure(error), renderer: renderer)
                default:
                    break
                }
            }
        }
    }

    /// End this phase at one point in the events, and begin the next with every event
    /// after it.
    func handOver() async -> PhaseEvents {
        let (next, stream) = await connection.replaceEventSubscription(subscription)
        return PhaseEvents(connection: connection, sessionId: sessionId, subscription: next, stream: stream)
    }

    /// End the phase, and return once everything it rendered is out. What a phase never
    /// rendered is not shown.
    func finish() async {
        await connection.endSubscription(subscription)
        await consumer?.value
    }
}

extension PermissionStats {
    /// What these totals counted since `earlier`, an earlier look at them.
    func counted(since earlier: PermissionStats) -> PermissionStats {
        var since = self
        since.requested -= earlier.requested
        since.approved -= earlier.approved
        since.denied -= earlier.denied
        since.cancelled -= earlier.cancelled
        return since
    }
}
