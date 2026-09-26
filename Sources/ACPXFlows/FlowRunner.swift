import ACPXCore
import Foundation
import SwiftACP

/// acpx's `FlowRunner` (`src/flows/runtime.ts`, v0.19.3): runs a flow one step at a time,
/// writing its run bundle as it goes. The flow's callbacks run in the ``FlowHost``; the
/// walk, the deadlines, the heartbeats and the bundle are here.
public actor FlowRunner {
    /// acpx's `flowRunsBaseDir`: `~/.acpx/flows/runs`, `~` as Node's `os.homedir()` has it.
    public static func runsBaseDir() -> URL {
        ACPXPaths.baseDir.appendingPathComponent("flows/runs", isDirectory: true)
    }

    /// acpx's default heartbeat and step timeout.
    static let defaultHeartbeatMs: Double = 5_000
    static let defaultStepTimeoutMs: Double = 15 * 60_000

    public struct Options: Sendable {
        /// Where runs go: `~/.acpx/flows/runs` unless a test says otherwise.
        public var outputRoot: URL
        /// The working directory relative ones are resolved against: the default agent's.
        public var defaultCwd: String
        /// acpx's `--timeout`, for a node that sets none (15 minutes without one).
        public var timeoutMs: Double?

        public init(outputRoot: URL = FlowRunner.runsBaseDir(), defaultCwd: String, timeoutMs: Double? = nil) {
            self.outputRoot = outputRoot
            self.defaultCwd = defaultCwd
            self.timeoutMs = timeoutMs
        }
    }

    /// acpx's `FlowRunResult`.
    public struct RunResult: Sendable {
        public let runDir: URL
        /// The run's state, as its projection has it.
        public let state: WireJSON
    }

    let host: FlowHost
    private let options: Options
    private let defaultNodeTimeoutMs: Double
    var store: FlowRunStore
    var state: FlowRunState
    private var runDir: URL?
    private var attempt: FlowAttempt?
    private var heartbeat: Task<Void, Never>?
    var interruption: FlowInterruptedError?
    /// Whether the steps have begun, with the bundle there to record an interrupt in.
    private var executing = false
    private var settled = false
    private var settledWaiters: [CheckedContinuation<Void, Never>] = []

    public init(host: FlowHost, options: Options) {
        self.host = host
        self.options = options
        defaultNodeTimeoutMs = options.timeoutMs ?? Self.defaultStepTimeoutMs
        store = FlowRunStore(outputRoot: options.outputRoot)
        state = FlowRunState(runId: "", flowName: "", runTitle: nil, flowPath: nil, input: .null, now: "")
        // `ctx.runShell` runs a command for a function action: not here yet (#202, step 2).
        host.setRequestHandler { method, _ in
            guard method == "shell/run" else { throw FlowHostError.methodNotFound(method) }
            throw FlowRunError("ctx.runShell is not supported by SwiftACP's acpx yet")
        }
    }

    // MARK: - The run

    /// acpx's `FlowRunner.run`: a waiting or completed run's result; a failed run's error,
    /// the bundle recording it.
    public func run(_ flow: FlowDescription, input: WireJSON, flowPath: String?) async throws -> RunResult {
        defer { markSettled() }
        _ = try await host.request("run/start", .object([("input", input)]))
        let runId = FlowRuntimeSupport.runId(flowName: flow.name)
        let runTitle = try await resolveRunTitle(flow, flowPath: flowPath)
        // Interrupted before the run began — while its title was worked out — it has
        // nothing to record.
        if let interruption { throw interruption }
        let runDir = try store.createRunDir(runId)
        self.runDir = runDir
        state = FlowRunState(
            runId: runId, flowName: flow.name, runTitle: runTitle, flowPath: flowPath, input: input, now: nowISO())
        let inputArtifact = try store.writeArtifact(
            runDir, state, content: .value(.json(input)), mediaType: "application/json", extension: "json",
            emitTrace: false)
        try store.initializeRunBundle(runDir, snapshot: flow.snapshot, state: state, inputArtifact: inputArtifact)
        return try await runWithOwnership(flow, runDir: runDir)
    }

    /// acpx's `runWithOwnership`: the run, and — when interrupted — the bundle marked
    /// failed with `Interrupted` once the run has stopped.
    private func runWithOwnership(_ flow: FlowDescription, runDir: URL) async throws -> RunResult {
        executing = true
        let outcome: Result<RunResult, Error>
        do {
            outcome = .success(try await executeFlowRun(flow, runDir: runDir))
        } catch {
            outcome = .failure(error)
        }
        if case .failure(let error) = outcome, error is FlowHost.Exited { throw error }
        if let interruption {
            try? persistRunFailure(runDir, interruption)
            throw interruption
        }
        return try outcome.get()
    }

    /// The run is interrupted (SIGINT, SIGTERM or SIGHUP): the step running is cancelled,
    /// and this returns once the run has stopped and recorded it. Before the steps began —
    /// its title still being worked out, say — there is nothing to wait for: acpx, which
    /// listens only once they begin, just exits.
    public func interrupt() async {
        guard interruption == nil else { return }
        let reason = FlowInterruptedError()
        interruption = reason
        attempt?.cancel(reason)
        if settled || !executing { return }
        await withCheckedContinuation { settledWaiters.append($0) }
    }

    private func markSettled() {
        settled = true
        let waiters = settledWaiters
        settledWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// acpx's `resolveFlowRunTitle`.
    private func resolveRunTitle(_ flow: FlowDescription, flowPath: String?) async throws -> String? {
        switch flow.title {
        case nil: return nil
        case .text(let text)?: return FlowRuntimeSupport.normalizeFlowRunTitle(text)
        case .function?:
            let resolved = try await host.request("flow/title", .object([("flowPath", flowPath.map(WireJSON.text))]))
            return FlowRuntimeSupport.normalizeFlowRunTitle(resolved?["value"]?.stringValue)
        }
    }

    /// acpx's `executeFlowRun`.
    private func executeFlowRun(_ flow: FlowDescription, runDir: URL) async throws -> RunResult {
        var current: String? = flow.startAt
        var attemptCounts: [String: Int] = [:]
        do {
            while let nodeId = current {
                try throwIfRunInterrupted()
                let step = try await executeFlowStep(
                    flow, nodeId: nodeId, attemptCounts: &attemptCounts, runDir: runDir)
                try throwIfRunInterrupted(step.executionError)
                if let waiting = try maybeCompleteCheckpointStep(step, runDir: runDir) { return waiting }
                try recordFlowStepOutcome(step, runDir: runDir)
                current = try resolveNextNode(flow, step)
                forgetAttempt(step)
            }
            return try completeFlowRun(runDir)
        } catch {
            if interruption == nil, !(error is FlowHost.Exited) { try? persistRunFailure(runDir, error) }
            throw error
        }
    }

    private func throwIfRunInterrupted(_ error: Error? = nil) throws {
        if let interruption { throw error ?? interruption }
    }

    // MARK: - A step

    /// What running a node gave: acpx's `FlowNodeExecutionResult`.
    struct Executed: Sendable {
        var output: FlowValue = .undefined
        /// Whether the output is a callback's value, which the host holds as it is.
        var outputFromHost = false
        var promptText: String?
        var rawText: String?
        var trace: FlowStepTrace?
    }

    /// acpx's `FlowStepExecutionResult`.
    struct Step: Sendable {
        let executed: Executed
        let result: FlowNodeResult
        let node: FlowNode
        let executionError: Error?

        var nodeId: String { node.id }
    }

    /// acpx's `executeFlowStep`.
    private func executeFlowStep(
        _ flow: FlowDescription, nodeId: String, attemptCounts: inout [String: Int], runDir: URL
    ) async throws -> Step {
        guard let node = flow.nodes[nodeId] else { throw FlowRunError("Unknown flow node: \(nodeId)") }
        let attemptId = FlowRuntimeSupport.nextAttemptId(&attemptCounts, nodeId: nodeId)
        let startedAt = nowISO()
        state.markNodeStarted(
            nodeId: nodeId, attemptId: attemptId, nodeType: node.nodeType.rawValue, startedAt: startedAt,
            detail: node.statusDetail)
        let timeoutMs = node.timeoutMs ?? defaultNodeTimeoutMs
        let attempt = FlowAttempt(nodeId: nodeId, attemptId: attemptId, startedAt: startedAt, timeoutMs: timeoutMs)
        let host = self.host
        attempt.setOnCancel { reason in
            let timeout = reason as? FlowTimeoutError
            host.notify("attempt/cancel", .object([
                ("attemptId", .text(attemptId)), ("reason", .text(timeout == nil ? "interrupted" : "timeout")),
                ("timeoutMs", timeout.map { .number($0.timeoutMs) })
            ]))
        }
        self.attempt = attempt
        var executed: Executed
        var outcome = FlowNodeOutcome.ok
        var executionError: Error?
        do {
            try throwIfRunInterrupted()
            executed = try await attempt.run { [self] in
                try await attempt.own {
                    try await self.writeNodeStartedSnapshot(node, attempt: attempt, runDir: runDir)
                }
                await self.startHeartbeat(node, attempt: attempt, runDir: runDir)
                var result = try await self.executeNode(node, attempt: attempt, runDir: runDir)
                let output = result.output
                let base = result.trace
                result.trace = try await attempt.own {
                    try await self.finalizeStepTrace(nodeId, attemptId, output: output, base: base, runDir: runDir)
                }
                return result
            }
            try throwIfRunInterrupted()
        } catch {
            outcome = Self.outcome(for: error)
            executionError = error
            executed = Executed(trace: try finalizeStepTrace(
                nodeId, attemptId, output: .undefined, base: (error as? FlowTracedError)?.trace, runDir: runDir))
        }
        heartbeat?.cancel()
        heartbeat = nil
        self.attempt = nil
        // The flow ended the host — `process.exit()`, a crash — which in acpx is the
        // process running the flow: gone with it, the run records nothing more.
        if let executionError, Self.isHostGone(executionError) { throw FlowHost.Exited() }
        var result = FlowNodeResult(
            attemptId: attemptId, nodeId: nodeId, nodeType: node.nodeType.rawValue, outcome: outcome,
            startedAt: startedAt, finishedAt: nowISO())
        if outcome == .ok {
            result.output = executed.output
        } else {
            result.error = executionError.map(TurnFailureText.message(of:)) ?? "undefined"
        }
        state.results[nodeId] = result.wire
        return Step(executed: executed, result: result, node: node, executionError: executionError)
    }

    /// Whether `error` is the host's going: itself, or among an attempt's cleanup failures.
    static func isHostGone(_ error: Error) -> Bool {
        error is FlowHost.Exited
            || (error as? FlowAttemptCleanupError)?.errors.contains { $0 is FlowHost.Exited } == true
    }

    /// acpx's `outcomeForError`.
    static func outcome(for error: Error) -> FlowNodeOutcome {
        switch error {
        case is FlowTimeoutError: return .timedOut
        case is FlowInterruptedError: return .cancelled
        default: return .failed
        }
    }

    /// acpx's `writeNodeStartedSnapshot`.
    private func writeNodeStartedSnapshot(_ node: FlowNode, attempt: FlowAttempt, runDir: URL) throws {
        let detail = state["statusDetail"]
        try store.writeSnapshot(
            runDir, &state, scope: "node", type: "node_started", nodeId: node.id, attemptId: attempt.attemptId,
            payload: .object([
                ("nodeType", .text(node.nodeType.rawValue)),
                ("timeoutMs", .number(node.timeoutMs ?? defaultNodeTimeoutMs)),
                ("statusDetail", detail.flatMap { $0.isEmpty ? nil : WireJSON.text($0) })
            ]))
    }

    /// acpx's `startHeartbeat`: while the attempt runs, a `node_heartbeat` every
    /// `heartbeatMs` (5 seconds by default; 0 for none), best effort, one at a time.
    private func startHeartbeat(_ node: FlowNode, attempt: FlowAttempt, runDir: URL) {
        let heartbeatMs = max(0, (node.heartbeatMs ?? Self.defaultHeartbeatMs).rounded(.toNearestOrAwayFromZero))
        guard heartbeatMs > 0 else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(heartbeatMs))
                guard !Task.isCancelled, attempt.active, let self else { return }
                _ = try? await attempt.own(bestEffort: true) { try await self.writeHeartbeat(attempt, runDir: runDir) }
            }
        }
    }

    private func writeHeartbeat(_ attempt: FlowAttempt, runDir: URL) throws {
        let now = nowISO()
        state["lastHeartbeatAt"] = now
        state["updatedAt"] = now
        try store.writeLive(
            runDir, &state, scope: "node", type: "node_heartbeat", nodeId: attempt.nodeId,
            attemptId: attempt.attemptId,
            payload: .object([("statusDetail", state["statusDetail"].map(WireJSON.text))]))
    }

    /// acpx's `executeNode`.
    private func executeNode(_ node: FlowNode, attempt: FlowAttempt, runDir: URL) async throws -> Executed {
        switch node.nodeType {
        case .compute, .checkpoint:
            return try await executeCallbackNode(node, attempt: attempt)
        case .action:
            guard node.hasRun else { throw FlowRunError("Shell action nodes are not supported by SwiftACP's acpx yet") }
            return try await executeCallbackNode(node, attempt: attempt)
        case .acp:
            throw FlowRunError("ACP nodes are not supported by SwiftACP's acpx yet")
        }
    }

    /// acpx's `executeCallbackNode`: the node's `run`, or — for a checkpoint without one —
    /// `{checkpoint, summary}`.
    private func executeCallbackNode(_ node: FlowNode, attempt: FlowAttempt) async throws -> Executed {
        try attempt.assertActive()
        let output: FlowValue
        let fromHost: Bool
        if node.nodeType == .checkpoint, !node.callbacks.contains("run") {
            output = .json(.object([("checkpoint", .text(node.id)), ("summary", .text(node.summary ?? node.id))]))
            fromHost = false
        } else {
            output = try await invoke(node, "run", attempt: attempt)
            fromHost = true
        }
        try attempt.assertActive()
        var trace: FlowStepTrace?
        if node.nodeType == .action {
            var functionTrace = FlowStepTrace()
            functionTrace["action"] = .object([("actionType", .text("function"))])
            trace = functionTrace
        }
        return Executed(output: output, outputFromHost: fromHost, trace: trace)
    }

    /// One callback of `node`, run by the host with the step context acpx builds
    /// (`makeFlowNodeContext`): the run's state as it is now.
    private func invoke(_ node: FlowNode, _ callback: String, attempt: FlowAttempt, argument: WireJSON? = nil)
        async throws -> FlowValue {
        var params: [(String, WireJSON?)] = [
            ("nodeId", .text(node.id)), ("fn", .text(callback)), ("attemptId", .text(attempt.attemptId))
        ]
        if let argument { params.append(("arg", argument)) }
        params.append(("state", state.wire))
        let reply = try await host.request("node/invoke", .object(params), attempt: attempt.attemptId)
        return FlowValue(reply: reply)
    }

    /// acpx's `finalizeStepTrace`: the step's output inline when it is short and on one
    /// line, else as an artifact — a failure to write it the step's.
    private func finalizeStepTrace(
        _ nodeId: String, _ attemptId: String, output: FlowValue, base: FlowStepTrace?, runDir: URL
    ) throws -> FlowStepTrace? {
        var trace = base ?? FlowStepTrace()
        if case .unserializable(let message) = output { throw FlowSerializationError(message: message) }
        if output != .undefined {
            if let inline = Self.inlineOutput(output) {
                trace["outputInline"] = inline
            } else {
                let isText: Bool
                if case .string? = output.json { isText = true } else { isText = false }
                let artifact = try store.writeArtifact(
                    runDir, state, content: .value(output), mediaType: isText ? "text/plain" : "application/json",
                    extension: isText ? "txt" : "json", nodeId: nodeId, attemptId: attemptId)
                trace["outputArtifact"] = artifact.wire
            }
        }
        return trace.isEmpty ? nil : trace
    }

    /// acpx's `toInlineOutput`.
    static func inlineOutput(_ output: FlowValue) -> WireJSON? {
        guard let json = output.json else { return nil }
        switch json {
        case .null, .number, .bool: return json
        case .string(let units): return FlowRuntimeSupport.isInlineSerializableText(units) ? json : nil
        default:
            return FlowRuntimeSupport.isInlineSerializableText(Array(json.stringified.utf16)) ? json : nil
        }
    }
}

/// A failure of the runner's own.
struct FlowRunError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What `JSON.stringify` threw for a node's output (a BigInt, a cycle).
struct FlowSerializationError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// An error that carries the step trace gathered before it (acpx's `attachStepTrace`).
struct FlowTracedError: Error, LocalizedError {
    let underlying: Error
    let trace: FlowStepTrace?
    var errorDescription: String? { TurnFailureText.message(of: underlying) }
}

extension FlowValue {
    /// A callback's value, as the host reports it.
    init(reply: WireJSON?) {
        if let message = reply?["unserializable"]?.stringValue {
            self = .unserializable(message)
        } else if reply?["jsonUndefined"] == .bool(true) {
            self = .unrepresentable
        } else if let value = reply?["value"] {
            self = .json(value)
        } else {
            self = .undefined
        }
    }
}
