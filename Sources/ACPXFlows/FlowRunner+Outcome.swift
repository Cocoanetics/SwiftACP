import ACPXCore
import Foundation
import SwiftACP

// What happens once a step is over: acpx's `maybeCompleteCheckpointStep`,
// `recordFlowStepOutcome`, `resolveNextNode` and how a run ends. Split from
// `FlowRunner.swift` to keep each file inside the 500-line limit.
extension FlowRunner {
    /// acpx's `maybeCompleteCheckpointStep`: a checkpoint that ran leaves the run waiting.
    func maybeCompleteCheckpointStep(_ step: Step, runDir: URL) throws -> RunResult? {
        guard step.result.outcome == .ok, step.node.nodeType == .checkpoint else { return nil }
        setOutput(step)
        state["waitingOn"] = step.nodeId
        state["updatedAt"] = nowISO()
        state["status"] = "waiting"
        // `output?.summary ?? nodeId`: the summary as it is, whatever its type.
        let summary = step.executed.output.json?["summary"]
        try recordFlowStepOutcome(step, runDir: runDir, statusDetail: summary == nil || summary == .null
            ? .text(step.nodeId) : summary)
        return RunResult(runDir: runDir, state: state.wire)
    }

    /// acpx's `recordFlowStepOutcome`.
    func recordFlowStepOutcome(_ step: Step, runDir: URL, statusDetail: WireJSON? = nil) throws {
        state["updatedAt"] = nowISO()
        state.clearActiveNode()
        state.set("statusDetail", statusDetail)
        state.steps.append(.object([
            ("attemptId", .text(step.result.attemptId)), ("nodeId", .text(step.nodeId)),
            ("nodeType", .text(step.node.nodeType.rawValue)), ("outcome", .text(step.result.outcome.rawValue)),
            ("startedAt", .text(step.result.startedAt)), ("finishedAt", .text(step.result.finishedAt)),
            ("promptText", step.executed.promptText.map(WireJSON.text) ?? .null),
            ("rawText", step.executed.rawText.map(WireJSON.text) ?? .null),
            ("output", step.executed.output.json), ("error", step.result.error.map(WireJSON.text)),
            ("session", .null), ("agent", .null), ("trace", step.executed.trace?.wire)
        ]))
        // acpx's `createNodeOutcomePayload`: the result, then the trace spread in.
        var payload: [(String, WireJSON?)] = [
            ("nodeType", .text(step.node.nodeType.rawValue)), ("outcome", .text(step.result.outcome.rawValue)),
            ("durationMs", .number(step.result.durationMs)), ("error", step.result.error.map(WireJSON.text) ?? .null)
        ]
        for member in step.executed.trace?.wire.objectMembers ?? [] {
            payload.append((String(decoding: member.key, as: UTF16.self), member.value))
        }
        try store.writeSnapshot(
            runDir, &state, scope: "node", type: "node_outcome", nodeId: step.nodeId, attemptId: step.result.attemptId,
            payload: .object(payload))
    }

    /// acpx's `resolveNextNode`: a step that succeeded is the node's output, and routes
    /// on it; one that failed goes on only by its result, else fails the run.
    func resolveNextNode(_ flow: FlowDescription, _ step: Step) throws -> String? {
        if step.result.outcome == .ok {
            setOutput(step)
            return try FlowGraph.resolveNext(
                flow.edges, from: step.nodeId, output: step.executed.output, result: step.result.wire,
                outcome: step.result.outcome.rawValue)
        }
        let next = try FlowGraph.resolveNext(
            flow.edges, from: step.nodeId, output: .undefined, result: step.result.wire,
            outcome: step.result.outcome.rawValue)
        if let next { return next }
        throw step.executionError ?? FlowRunError("undefined")
    }

    /// The host need hold no value of a step that is over, whose output is committed; nor
    /// need the runner wait any longer for a callback of it that never settled.
    func forgetAttempt(_ step: Step) {
        host.notify("attempt/forget", .object([("attemptId", .text(step.result.attemptId))]))
        host.abandon(attempt: step.result.attemptId)
        if let attempt = attempts.removeValue(forKey: step.result.attemptId) {
            retiredAttempts[step.result.attemptId] = .some(attempt.abortReason)
        }
    }

    /// acpx's `setNodeValue` for `outputs`, here and in the host, whose callbacks see it:
    /// a callback's value as the host holds it, anything else as JSON.
    func setOutput(_ step: Step) {
        state.setOutput(step.nodeId, step.executed.output)
        var params: [(String, WireJSON?)] = [("nodeId", .text(step.nodeId))]
        if step.executed.outputFromHost {
            params.append(("attemptId", .text(step.result.attemptId)))
        } else {
            params.append(("value", step.executed.output.json ?? .null))
        }
        host.notify("outputs/set", .object(params))
    }

    /// acpx's `completeFlowRun`.
    func completeFlowRun(_ runDir: URL) throws -> RunResult {
        state["status"] = "completed"
        let finishedAt = nowISO()
        state["finishedAt"] = finishedAt
        state["updatedAt"] = finishedAt
        state.clearActiveNode()
        try store.writeSnapshot(
            runDir, &state, scope: "run", type: "run_completed", payload: .object([("status", .text("completed"))]))
        return RunResult(runDir: runDir, state: state.wire)
    }

    /// acpx's `persistRunFailure`: the run failed — or timed out — with `error`, once.
    func persistRunFailure(_ runDir: URL, _ error: Error) throws {
        if state["finishedAt"] != nil, state.status == "failed" || state.status == "timed_out" { return }
        state["status"] = error is FlowTimeoutError ? "timed_out" : "failed"
        let now = nowISO()
        state["updatedAt"] = now
        state["finishedAt"] = now
        let message = TurnFailureText.message(of: error)
        state["error"] = message
        state["statusDetail"] = state["currentNode"].map { "Failed in \($0): \(message)" } ?? message
        try store.writeSnapshot(
            runDir, &state, scope: "run", type: "run_failed",
            payload: .object([("status", .text(state.status)), ("error", .text(message))]))
    }
}
