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
    /// input, and each step's output — in the step, the node's result and `outputs` — by the
    /// attempt that produced it. What the host cannot say stays as it was.
    ///
    /// A value the state writes that JSON can no longer write — a BigInt added to an output, a
    /// cycle — throws its error, as acpx's `JSON.stringify` of the state throws as it writes:
    /// the snapshot is not written, and the run fails with it.
    func refreshLiveValues() async throws {
        let host = self.host
        let reply = try? await withTimeout(milliseconds: Self.liveValuesWaitMilliseconds) {
            try await host.request("state/current", .object([WireJSON.Member]()))
        }
        guard let current = reply ?? nil else { return }
        switch FlowValue(reply: current["input"]) {
        case .json(let input): state.set("input", input)
        case .unserializable(let message): throw FlowRunError(message)
        default: break
        }
        guard case .object(let attempts)? = current["attempts"] else { return }
        let written = writtenAttempts
        var values: [String: WireJSON] = [:]
        for member in attempts {
            let attemptId = String(decoding: member.key, as: UTF16.self)
            switch FlowValue(reply: member.value) {
            case .json(let value): values[attemptId] = value
            case .unserializable(let message) where written.contains(attemptId): throw FlowRunError(message)
            default: break
            }
        }
        guard !values.isEmpty else { return }
        state.steps = state.steps.map { Self.withLiveOutput($0, from: values) }
        for nodeId in state.results.keys {
            state.results[nodeId] = state.results[nodeId].map { Self.withLiveOutput($0, from: values) }
        }
        for (nodeId, attemptId) in outputAttempts {
            if let value = values[attemptId] { state.outputs[nodeId] = value }
        }
    }

    /// acpx's `persistRunFailure`, best effort, with the live values: none is written when one
    /// can no longer be — acpx's write of it throws, and the bundle stays as it last was.
    func persistRunFailureLive(_ runDir: URL, _ error: Error) async {
        guard (try? await refreshLiveValues()) != nil else { return }
        try? persistRunFailure(runDir, error)
    }

    /// The attempts whose outputs the state writes: in a step or a node's result that has one,
    /// or in `outputs`. A step whose own value JSON could not write has none: it failed.
    private var writtenAttempts: Set<String> {
        let records = state.steps + state.results.keys.compactMap { state.results[$0] }
        let recorded = records.compactMap { record in
            record.hasMember("output") ? record["attemptId"]?.stringValue : nil
        }
        return Set(recorded).union(outputAttempts.values)
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
