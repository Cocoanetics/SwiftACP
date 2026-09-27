import ACPXCore
import Foundation
import SwiftACP

// The run's live values, as acpx writes them (#206). acpx's run state holds a node's output and
// the run's input as the objects the flow's code has, and its projections are that state as
// `JSON.stringify` writes it when it writes: a change to one of them after its step — through
// `ctx.outputs` or `ctx.input`, or on its own — reaches every projection written after, and the
// run's result. The host holds those objects here. Split from `FlowRunner.swift` to keep it
// inside the 500-line limit.
extension FlowRunner {
    /// How long a snapshot waits for the host's live values. One whose callback holds its event
    /// loop — which in acpx would hold the runner too — leaves the last JSON.
    static let liveValuesWaitMilliseconds = 5_000

    /// The run's live values, as the host holds them now, into the state a snapshot writes: the
    /// input — left out when JSON has nothing for it; `outputs` as the flow's code holds it, since `ctx.outputs` is acpx's `state.outputs`
    /// — a member a callback replaced, deleted or added is so — and each step's output, in the
    /// step and the node's result, by the attempt that produced it. What the host cannot say
    /// stays as it was.
    ///
    /// A value the state writes that JSON can no longer write — a BigInt added to an output, a
    /// cycle — throws its error, as acpx's `JSON.stringify` of the state throws as it writes:
    /// the snapshot is not written, and the run fails with it.
    ///
    /// Returns what each attempt's callback returned last, not committed yet: a step's own value
    /// only when its output is that callback's (``FlowRunner/Executed/outputFromHost``).
    @discardableResult
    func refreshLiveValues() async throws -> [String: FlowValue] {
        let host = self.host
        let reply = try? await withTimeout(milliseconds: Self.liveValuesWaitMilliseconds) {
            try await host.request("state/current", .object([WireJSON.Member]()))
        }
        guard let current = reply ?? nil else { return [:] }
        switch FlowValue(reply: current["input"]) {
        case .json(let input): state.set("input", input)
        case .unrepresentable: state.set("input", nil)
        case .unserializable(let message): throw FlowRunError(message)
        default: break
        }
        let outputs = FlowValue(reply: current["outputs"])
        if case .unserializable(let message) = outputs { throw FlowRunError(message) }
        state.replaceOutputs(with: outputs)
        let returned = Self.values(current["returned"])
        guard case .object(let attempts)? = current["attempts"] else { return returned }
        let written = writtenAttempts
        var values: [String: WireJSON] = [:]
        for member in attempts {
            let attemptId = String(decoding: member.key, as: UTF16.self)
            switch FlowValue(reply: member.value) {
            case .json(let value):
                values[attemptId] = value
                state.omittedOutputs.remove(attemptId)
            case .unserializable(let message) where written.contains(attemptId): throw FlowRunError(message)
            case .unrepresentable where written.contains(attemptId): state.omittedOutputs.insert(attemptId)
            default: break
            }
        }
        state.steps = state.steps.map { Self.withLiveOutput($0, from: values) }
        for nodeId in state.results.keys {
            state.results[nodeId] = state.results[nodeId].map { Self.withLiveOutput($0, from: values) }
        }
        return returned
    }

    /// A step whose output is its callback's own value, with that value as the flow's code holds
    /// it now — in the step, and in the node's result the run's state holds. One JSON can no
    /// longer write fails the run, as acpx's write of the step throws.
    func recordLive(_ live: FlowValue, of step: Step) throws -> Step {
        switch live {
        case .json, .unrepresentable:
            let patched = step.withLive(live)
            if patched.result.outcome == .ok { state.keepResult(patched.result) }
            return patched
        case .unserializable(let message) where step.result.outcome == .ok:
            throw FlowRunError(message)
        default:
            return step
        }
    }

    /// A host reply's values by attempt.
    private static func values(_ reply: WireJSON?) -> [String: FlowValue] {
        guard case .object(let members)? = reply else { return [:] }
        var values: [String: FlowValue] = [:]
        for member in members { values[String(decoding: member.key, as: UTF16.self)] = FlowValue(reply: member.value) }
        return values
    }

    /// The run's input once its title is worked out: a title function is handed the input
    /// itself, as acpx's is, so a change it makes is the run's — in its state and in the input
    /// artifact, where one JSON has nothing for is written `undefined` — and one JSON can no
    /// longer write fails the run, as acpx's write of it throws (#206 review).
    func inputAfterTitle(_ flow: FlowDescription, given input: WireJSON) async throws -> FlowValue {
        guard case .function? = flow.title else { return .json(input) }
        let host = self.host
        let reply = try? await withTimeout(milliseconds: Self.liveValuesWaitMilliseconds) {
            try await host.request("state/current", .object([WireJSON.Member]()))
        }
        switch FlowValue(reply: (reply ?? nil)?["input"]) {
        case .json(let value): return .json(value)
        case .unrepresentable: return .unrepresentable
        case .unserializable(let message): throw FlowRunError(message)
        default: return .json(input)
        }
    }

    /// acpx's `persistRunFailure`, best effort, with the live values: none is written when one
    /// can no longer be — acpx's write of it throws, and the bundle stays as it last was.
    func persistRunFailureLive(_ runDir: URL, _ error: Error) async {
        guard (try? await refreshLiveValues()) != nil else { return }
        try? persistRunFailure(runDir, error)
    }

    /// The attempts whose outputs the state holds, in a step or a node's result that has one —
    /// though JSON has nothing for it now (``FlowRunState/keepOutput(_:of:)``). A step whose own
    /// value JSON could not write has none: it failed.
    private var writtenAttempts: Set<String> {
        let records = state.steps + state.results.keys.compactMap { state.results[$0] }
        return Set(records.compactMap { record in
            record.hasMember("output") ? record["attemptId"]?.stringValue : nil
        })
    }

    /// `record` — a step, or a node's result — with its `output` the live value of its attempt,
    /// when it has an output and the host a value for it. So is a step's trace's `outputInline`,
    /// which in acpx is the output itself; an `outputArtifact` is the file written as the step
    /// ended.
    private static func withLiveOutput(_ record: WireJSON, from values: [String: WireJSON]) -> WireJSON {
        guard let attemptId = record["attemptId"]?.stringValue, let value = values[attemptId] else { return record }
        var live = record.replacing("output", with: value)
        if let trace = record["trace"], trace.hasMember("outputInline") {
            live = live.replacing("trace", with: trace.replacing("outputInline", with: value))
        }
        return live
    }
}

extension FlowRunner.Step {
    /// The step with `value` — its output as the flow's code holds it now, or nothing JSON can
    /// write — as its output: in what it executed, its trace's `outputInline`, and its result,
    /// when it has one. An `outputInline` keeps its place while JSON has nothing for it: the
    /// state leaves it out when written, and writes it there again once JSON has.
    func withLive(_ value: FlowValue) -> FlowRunner.Step {
        guard executed.output.holdsAnObject else { return self }
        var executed = self.executed
        executed.output = value
        if let json = value.json, executed.trace?.members["outputInline"] != nil {
            executed.trace?.members["outputInline"] = json
        }
        var result = self.result
        if result.output.holdsAnObject { result.output = value }
        return FlowRunner.Step(executed: executed, result: result, node: node, executionError: executionError)
    }
}

extension FlowValue {
    /// Whether this can be an object the flow's code still holds, whose JSON can change: JSON,
    /// or nothing JSON can write for now.
    var holdsAnObject: Bool {
        switch self {
        case .json, .unrepresentable: return true
        case .undefined, .unserializable: return false
        }
    }

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
