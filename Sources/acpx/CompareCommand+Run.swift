import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

// One agent's run for `compare`, as acpx's `runAgentForCompare` has `runOnce` do it —
// along `exec`'s path — and its row. Split from `CompareCommand.swift` to keep each file
// short.
extension CompareCommand {
    /// acpx's `runAgentForCompare`: the agent run, and a row for how it went — a
    /// success row for an answered prompt, an error row for a failure.
    static func runAgent(_ agentName: String, _ job: Job) -> Row {
        let started = DispatchTime.now()
        let capture = RunCapture()
        let wallMs = { Int((Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6).rounded()) }
        do {
            let agent = try Flags.resolveAgentInvocation(agentName, job.flags, config: job.config)
            let response = try runBlocking { try await runOnce(agent, job, capture: capture) }
            // acpx's `runOnce` fails a run that needed a question nobody could be asked.
            if capture.permissions.promptUnavailable {
                return errorRow(agentName, ExecCommand.PromptUnavailable(), capture, wallMs: wallMs())
            }
            return successRow(agentName, response, capture, wallMs: wallMs())
        } catch {
            return errorRow(agentName, error, capture, wallMs: wallMs())
        }
    }

    /// acpx's `runOnce` with `compare`'s options: the agent launched, a session with the
    /// invocation's session options, the prompt under `--prompt-retries` — each step within
    /// the timeout (``Job/timeoutMs``) — its output discarded. At a signal the run is put
    /// down as `exec`'s is (``RunInterrupt``).
    private static func runOnce(
        _ agent: AgentInvocation, _ job: Job, capture: RunCapture
    ) async throws -> PromptResponse {
        let interrupt = RunInterrupt()
        do {
            let response = try await runPutDownAtASignal(agent, job, capture: capture, interrupt: interrupt)
            await capture.stopFollowing()
            return response
        } catch {
            await capture.stopFollowing()
            throw error
        }
    }

    /// ``runOnce(_:_:capture:)`` under acpx's `withInterrupt`.
    private static func runPutDownAtASignal(
        _ agent: AgentInvocation, _ job: Job, capture: RunCapture, interrupt: RunInterrupt
    ) async throws -> PromptResponse {
        try await Interrupts.withInterrupt({
            let flags = job.flags
            let handle = try await interrupt.launch {
                try await ExecCommand.launchAgent(within: job.timeoutMs) {
                    try await ACPAgent.launch(
                        agent: agent.agentCommand, argv: agent.agentArgv, cwd: agent.cwd, permission: job.permission,
                        nonInteractivePermissions: flags.nonInteractivePolicy, permissionRules: job.permissionRules,
                        capabilities: flags.clientCapabilities, authCredentials: job.config.auth,
                        authPolicy: flags.authPolicy, inheritStderr: flags.verbose,
                        onRawWire: { capture.answer.observe($0, $1) })
                }
            }
            await capture.follow(handle.connection)
            do {
                let response = try await prompt(on: handle, agent, job, capture: capture, interrupt: interrupt)
                await handle.close()
                return response
            } catch {
                await handle.close()
                throw error
            }
        }, onInterrupt: { await interrupt.putDown(endInterrupted: $0) })
    }

    /// The session, then the prompt, as `exec` goes about them — with nothing shown.
    private static func prompt(
        on handle: ACPAgent, _ agent: AgentInvocation, _ job: Job, capture: RunCapture, interrupt: RunInterrupt
    ) async throws -> PromptResponse {
        let sideEffects = PromptSideEffects()
        await handle.connection.setWireMessageObserver { sideEffects.observe($0, $1) }
        let session = try await ExecCommand.openSession(
            on: handle, agent: agent, mcpServers: job.mcpServers,
            meta: SessionLifecycle.sessionMeta(agent: agent, flags: job.flags), model: job.flags.model,
            configOptions: [], timeoutMs: job.timeoutMs, quiet: true)
        capture.opened(session.id)
        interrupt.opened(session.id)
        let discarded = OutputRenderer(
            options: RenderOptions(format: .quiet), out: { _ in }, err: { _ in }, color: false)
        let policy = ExecCommand.PromptPolicy(
            timeoutMilliseconds: job.timeoutMs, retries: job.flags.promptRetries ?? 0, quiet: true)
        return try await ExecCommand.runPrompt(
            job.prompt, on: session, policy: policy, renderer: discarded, sideEffects: sideEffects
        ).response
    }

    /// acpx's `buildSuccessRow`.
    private static func successRow(
        _ agentName: String, _ response: PromptResponse, _ capture: RunCapture, wallMs: Int
    ) -> Row {
        let stats = capture.permissions
        var row = Row(
            agent: agentName, status: "ok", stopReason: response.stopReason.rawValue, wallMs: wallMs,
            usage: capture.usage, finalMessage: truncate(capture.text.javaScriptCollapsed, previewChars), error: nil,
            permissionRequests: stats.requested, permissionDenied: stats.denied + stats.cancelled)
        if let answer = capture.answer.result, answer.hasMember("_meta") { row.meta = answer["_meta"] }
        if response.stopReason == .cancelled {
            row.status = "cancelled"
        } else if stats.denied + stats.cancelled > 0 {
            row.status = "permission_denied"
        }
        return row
    }

    /// acpx's `buildErrorRow`: what the agent said so far, and the error's message.
    private static func errorRow(_ agentName: String, _ error: Error, _ capture: RunCapture, wallMs: Int) -> Row {
        let stats = capture.permissions
        let failure = ExecCommand.RunFailure(error)
        return Row(
            agent: agentName, status: status(of: error, failure), stopReason: nil, wallMs: wallMs, usage: capture.usage,
            finalMessage: truncate(capture.text.javaScriptCollapsed, previewChars),
            error: truncate(failure.message.javaScriptCollapsed, previewChars),
            permissionRequests: stats.requested, permissionDenied: stats.denied + stats.cancelled)
    }

    /// acpx's `rowStatusFromError`: a timeout is `cancelled`, a permission refused or
    /// that nobody could be asked for `permission_denied`, anything else `error`.
    private static func status(of error: Error, _ failure: ExecCommand.RunFailure) -> String {
        if error is TimeoutError { return "cancelled" }
        return ["PERMISSION_PROMPT_UNAVAILABLE", "PERMISSION_DENIED"].contains(failure.outputCode)
            ? "permission_denied" : "error"
    }
}

/// What a run said, as acpx's `RunCapture` has it: the text of the agent's message
/// chunks, the usage of its last `usage_update`, and the permissions the run needed —
/// from all of the run, retries and pauses included.
final class RunCapture: @unchecked Sendable {
    /// The prompt's answer as it crossed the wire, whose `_meta` a success row carries.
    let answer = PromptResultCapture()
    private let lock = NSLock()
    private var chunks = ""
    private var lastUsage = CompareCommand.TokenUsage()
    private var sessionId: SessionId?
    private var connection: ACPAgentConnection?
    private var subscription: UUID?
    private var consumer: Task<Void, Never>?
    private var stats = PermissionStats()

    var text: String { lock.withLock { chunks } }
    var usage: CompareCommand.TokenUsage { lock.withLock { lastUsage } }
    var permissions: PermissionStats { lock.withLock { stats } }

    /// Take in the session updates of `connection` from now on.
    func follow(_ connection: ACPAgentConnection) async {
        let (subscription, stream) = await connection.makeEventSubscription()
        let consumer = Task { [weak self] in
            for await event in stream {
                guard case .update(let note) = event else { continue }
                self?.take(note.update)
            }
        }
        lock.withLock {
            self.connection = connection
            self.subscription = subscription
            self.consumer = consumer
        }
    }

    func opened(_ sessionId: SessionId) {
        lock.withLock { self.sessionId = sessionId }
    }

    /// Stop taking updates in, once those already come are taken, and read the run's
    /// permission counts as they stand — acpx's `onPermissionStats`, from its `finally`.
    func stopFollowing() async {
        let (connection, subscription, consumer, sessionId) = lock.withLock {
            (self.connection, self.subscription, self.consumer, self.sessionId)
        }
        guard let connection else { return }
        if let subscription { await connection.endSubscription(subscription) }
        await consumer?.value
        if let sessionId {
            // Every attempt's, and the pauses', as acpx's client counts them.
            let stats = await connection.permissionTotals(for: sessionId)
            lock.withLock { self.stats = stats }
        }
    }

    /// acpx's `captureSessionUpdate`.
    private func take(_ update: SessionUpdate) {
        switch update {
        case .agentMessageChunk(.text(let content)):
            lock.withLock { chunks += content.text }
        case .usageUpdate(let usage) where usage.reachesACPX:
            let captured = Self.usage(of: usage)
            lock.withLock { lastUsage = captured }
        default:
            break
        }
    }

    /// acpx's `captureUsage`: `_meta.usage` in snake or camel case. Its fallback, the
    /// update itself, never has any: acpx's SDK keeps only `used`, `size`, `cost` and
    /// `_meta` of a `usage_update`, and drops one without `used` and `size` (#155).
    private static func usage(of update: UsageUpdate) -> CompareCommand.TokenUsage {
        guard let usage = update.acpxTokenUsage else { return CompareCommand.TokenUsage() }
        func number(_ keys: [String]) -> Double? {
            for key in keys {
                switch usage[key] {
                case .integer(let value)?: return Double(value)
                case .unsignedInteger(let value)?: return Double(value)
                case .double(let value)? where value.isFinite: return value
                default: continue
                }
            }
            return nil
        }
        return CompareCommand.TokenUsage(
            input: number(["input_tokens", "inputTokens"]), output: number(["output_tokens", "outputTokens"]),
            total: number(["total_tokens", "totalTokens"]))
    }
}
