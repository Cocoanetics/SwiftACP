import ACPXCore
import Foundation
import SwiftACP

/// A value a flow produced, as the runner keeps it.
public enum FlowValue: Equatable, Sendable {
    /// `undefined`: left out wherever it is written.
    case undefined
    /// A function or a symbol, which `JSON.stringify` makes `undefined` inside an object
    /// and writes as the text `undefined` on its own.
    case unrepresentable
    case json(WireJSON)
    /// A value `JSON.stringify` throws for (a BigInt, a cycle), and its message: the step
    /// that produced it fails when acpx's runner writes it.
    case unserializable(String)

    /// The value as JSON, `nil` when JSON has none for it.
    public var json: WireJSON? {
        if case .json(let value) = self { return value }
        return nil
    }
}

/// A JavaScript object's own members, in the order they were first set: one set to
/// `undefined` keeps its place, and is left out when the object is written, as
/// `JSON.stringify` leaves it out.
struct JSObject: Equatable, Sendable {
    private(set) var keys: [String] = []
    private var values: [String: WireJSON] = [:]

    subscript(key: String) -> WireJSON? {
        get { values[key] }
        set {
            if values[key] == nil, !keys.contains(key) { keys.append(key) }
            values[key] = newValue
        }
    }

    var isEmpty: Bool { values.isEmpty }

    /// The object as `JSON.stringify` writes it.
    var wire: WireJSON {
        .object(keys.compactMap { key in values[key].map { WireJSON.Member(key, $0) } })
    }
}

/// acpx's `FlowRunState`: what a run is doing and has done, as the projections write it.
struct FlowRunState: Sendable {
    /// The run's members, in the order acpx's runner first sets them.
    private(set) var members = JSObject()
    var outputs = JSObject()
    var results = JSObject()
    var steps: [WireJSON] = []
    var sessionBindings = JSObject()

    /// The state acpx's `FlowRunner.run` starts with.
    init(runId: String, flowName: String, runTitle: String?, flowPath: String?, input: WireJSON, now: String) {
        self["runId"] = runId
        self["flowName"] = flowName
        self["runTitle"] = runTitle
        self["flowPath"] = flowPath
        self["startedAt"] = now
        self["updatedAt"] = now
        self["status"] = "running"
        members["input"] = input
        // Placeholders for the containers, so they keep their place among the members.
        for key in ["outputs", "results", "steps", "sessionBindings"] { members[key] = .object([WireJSON.Member]()) }
    }

    /// A string member, `nil` for `undefined`. Setting one that was never set adds it
    /// last, as assigning a new property does.
    subscript(key: String) -> String? {
        get { members[key]?.stringValue }
        set { members[key] = newValue.map(WireJSON.text) }
    }

    /// A member of any JSON value, `nil` for `undefined`.
    mutating func set(_ key: String, _ value: WireJSON?) {
        members[key] = value
    }

    var runId: String { self["runId"] ?? "" }
    var flowName: String { self["flowName"] ?? "" }
    var status: String { self["status"] ?? "" }
    var input: WireJSON { members["input"] ?? .null }

    /// The state as `JSON.stringify` writes it (`projections/run.json`).
    var wire: WireJSON {
        var object = members
        object["outputs"] = outputs.wire
        object["results"] = results.wire
        object["steps"] = .array(steps)
        object["sessionBindings"] = sessionBindings.wire
        return object.wire
    }

    /// acpx's `createLiveState` (`projections/live.json`).
    var live: WireJSON {
        let keys = [
            "runId", "flowName", "runTitle", "flowPath", "startedAt", "finishedAt", "updatedAt", "status",
            "currentNode", "currentAttemptId", "currentNodeType", "currentNodeStartedAt", "lastHeartbeatAt",
            "statusDetail", "waitingOn", "error"
        ]
        return .object(keys.map { ($0, members[$0]) } + [("sessionBindings", sessionBindings.wire)])
    }

    /// acpx's `markNodeStarted`.
    mutating func markNodeStarted(
        nodeId: String, attemptId: String, nodeType: String, startedAt: String, detail: String?
    ) {
        self["status"] = "running"
        self["waitingOn"] = nil
        self["currentNode"] = nodeId
        self["currentAttemptId"] = attemptId
        self["currentNodeType"] = nodeType
        self["currentNodeStartedAt"] = startedAt
        self["lastHeartbeatAt"] = startedAt
        self["statusDetail"] = detail ?? "Running \(nodeType) node \(nodeId)"
    }

    /// acpx's `clearActiveNode`.
    mutating func clearActiveNode(detail: String? = nil) {
        self["currentNode"] = nil
        self["currentAttemptId"] = nil
        self["currentNodeType"] = nil
        self["currentNodeStartedAt"] = nil
        self["lastHeartbeatAt"] = nil
        self["statusDetail"] = detail
    }

    /// acpx's `updateStatusDetail`: a detail given replaces the one there.
    mutating func updateStatusDetail(_ detail: String?) {
        guard let detail, !detail.isEmpty else { return }
        self["statusDetail"] = detail
    }

    /// acpx's `setNodeValue`: `outputs[nodeId]` defined as an own property, so any id —
    /// `__proto__` among them — is an ordinary key.
    mutating func setOutput(_ nodeId: String, _ value: FlowValue) {
        outputs[nodeId] = value.json
    }
}

/// acpx's `FlowNodeOutcome`.
enum FlowNodeOutcome: String, Sendable {
    case ok
    case timedOut = "timed_out"
    case failed
    case cancelled
}

/// acpx's `FlowNodeResult` (`createNodeResult`).
struct FlowNodeResult: Sendable {
    let attemptId: String
    let nodeId: String
    let nodeType: String
    let outcome: FlowNodeOutcome
    let startedAt: String
    let finishedAt: String
    var output: FlowValue = .undefined
    var error: String?

    var durationMs: Double { FlowRuntimeSupport.durationMs(from: startedAt, to: finishedAt) }

    var wire: WireJSON {
        .object([
            ("attemptId", .text(attemptId)), ("nodeId", .text(nodeId)), ("nodeType", .text(nodeType)),
            ("outcome", .text(outcome.rawValue)), ("startedAt", .text(startedAt)), ("finishedAt", .text(finishedAt)),
            ("durationMs", .number(durationMs)), ("output", output.json), ("error", error.map(WireJSON.text))
        ])
    }
}

/// acpx's `FlowArtifactRef`.
struct FlowArtifactRef: Equatable, Sendable {
    let path: String
    let mediaType: String
    let bytes: Int
    let sha256: String

    var wire: WireJSON {
        .object([
            ("path", .text(path)), ("mediaType", .text(mediaType)), ("bytes", .number(Double(bytes))),
            ("sha256", .text(sha256))
        ])
    }
}

/// acpx's `FlowStepTrace`, its members in the order the runner sets them.
struct FlowStepTrace: Sendable {
    var members = JSObject()

    var isEmpty: Bool { members.isEmpty }
    var wire: WireJSON { members.wire }

    subscript(key: String) -> WireJSON? {
        get { members[key] }
        set { members[key] = newValue }
    }
}

extension WireJSON {
    /// An object literal's members in order, those `nil` (`undefined`) left out, as
    /// `JSON.stringify` writes it.
    static func object(_ members: [(String, WireJSON?)]) -> WireJSON {
        .object(members.compactMap { key, value in value.map { Member(key, $0) } })
    }

    /// The object's members, in order; none for anything else.
    var objectMembers: [Member] {
        if case .object(let members) = self { return members }
        return []
    }
}
