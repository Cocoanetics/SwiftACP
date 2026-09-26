import Foundation
import SwiftACP

/// A flow as the host loaded it: acpx's `FlowDefinition` less its callbacks, which stay
/// in the host, and its definition snapshot as acpx writes it to `flow.json`.
public struct FlowDescription: Sendable {
    public let name: String
    public let startAt: String
    /// The edges as the flow gives them (acpx routes on them as they are).
    let edges: [WireJSON]
    public let permissions: FlowPermissionRequirements?
    let title: Title?
    /// acpx's `createFlowDefinitionSnapshot` of the flow.
    let snapshot: WireJSON
    /// The nodes, by id, as the flow gives them.
    let nodes: [String: FlowNode]

    /// `run.title`: a string, or a function the host calls.
    enum Title: Sendable {
        case text(String)
        case function
    }

    public init(loaded: WireJSON) throws {
        guard let name = loaded["name"]?.stringValue, let startAt = loaded["startAt"]?.stringValue else {
            throw FlowDescriptionError("The flow host described no flow")
        }
        self.name = name
        self.startAt = startAt
        if case .array(let edges)? = loaded["edges"] { self.edges = edges } else { self.edges = [] }
        permissions = loaded["permissions"].flatMap(FlowPermissionRequirements.init)
        if let text = loaded["title"]?["value"]?.stringValue {
            title = .text(text)
        } else if loaded["title"]?["function"] == .bool(true) {
            title = .function
        } else {
            title = nil
        }
        snapshot = loaded["snapshot"] ?? .object([WireJSON.Member]())
        var nodes: [String: FlowNode] = [:]
        if case .array(let described)? = loaded["nodes"] {
            for node in described {
                guard let parsed = FlowNode(node) else { continue }
                nodes[parsed.id] = parsed
            }
        }
        self.nodes = nodes
    }
}

struct FlowDescriptionError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// acpx's `FlowPermissionRequirements`.
public struct FlowPermissionRequirements: Sendable {
    public let requiredMode: String
    public let requireExplicitGrant: Bool
    public let reason: String?

    init?(_ value: WireJSON) {
        guard let requiredMode = value["requiredMode"]?.stringValue else { return nil }
        self.requiredMode = requiredMode
        requireExplicitGrant = value["requireExplicitGrant"] == .bool(true)
        reason = value["reason"]?.stringValue
    }
}

/// One node as the flow defines it, but for its callbacks: which it has.
struct FlowNode: Sendable {
    enum NodeType: String, Sendable {
        case acp, compute, action, checkpoint
    }

    let id: String
    let nodeType: NodeType
    let timeoutMs: Double?
    let heartbeatMs: Double?
    let statusDetail: String?
    let summary: String?
    let profile: String?
    let sessionHandle: String?
    let isolated: Bool
    /// A static working directory (a `cwd` function is a callback).
    let cwd: String?
    /// The callbacks it has: `run`, `prompt`, `parse`, `exec`, `cwd`.
    let callbacks: Set<String>
    /// Whether it has its own `run` / `exec` member, whatever its value.
    let hasRun: Bool
    let hasExec: Bool

    init?(_ value: WireJSON) {
        guard let id = value["id"]?.stringValue, let type = value["nodeType"]?.stringValue,
              let nodeType = NodeType(rawValue: type)
        else { return nil }
        self.id = id
        self.nodeType = nodeType
        timeoutMs = value["timeoutMs"]?.numberValue
        heartbeatMs = value["heartbeatMs"]?.numberValue
        statusDetail = value["statusDetail"]?.stringValue
        summary = value["summary"]?.stringValue
        profile = value["profile"]?.stringValue
        sessionHandle = value["session"]?["handle"]?.stringValue
        isolated = value["session"]?["isolated"] == .bool(true)
        cwd = value["cwd"]?.stringValue
        if case .array(let names)? = value["callbacks"] {
            callbacks = Set(names.compactMap(\.stringValue))
        } else {
            callbacks = []
        }
        hasRun = value["hasRun"] == .bool(true)
        hasExec = value["hasExec"] == .bool(true)
    }

    /// A function action, which gets `ctx.runShell` (`"run" in node`).
    var isFunctionAction: Bool { nodeType == .action && hasRun }
}

/// acpx's `src/flows/graph.ts`: where a step goes next.
enum FlowGraph {
    struct RoutingError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// acpx's `resolveNext`: the node the edge out of `from` leads to — none without one,
    /// or when the step did not succeed and the edge does not route on its result.
    static func resolveNext(
        _ edges: [WireJSON], from: String, output: FlowValue, result: WireJSON?, outcome: String?
    ) throws -> String? {
        guard let edge = edges.first(where: { $0["from"]?.stringValue == from }) else { return nil }
        let direct = edge.hasMember("to")
        let switchOn = edge["switch"]?["on"]?.stringValue ?? ""
        let canFollow = outcome == nil || outcome == "ok" || (!direct && switchOn.hasPrefix("$result."))
        guard canFollow else { return nil }
        if direct { return edge["to"]?.stringValue }

        let value = try switchValue(output: output, result: result, path: switchOn)
        guard let key = value.flatMap(scalarString) else {
            throw RoutingError(message: "Flow switch value must be scalar for \(switchOn)")
        }
        guard let cases = edge["switch"]?["cases"], cases.hasMember(key) else {
            throw RoutingError(message: "No flow switch case for \(switchOn)=\(value?.stringified ?? "undefined")")
        }
        return cases[key]?.stringValue
    }

    /// acpx's `getBySwitchPath`.
    private static func switchValue(output: FlowValue, result: WireJSON?, path: String) throws -> WireJSON? {
        if path.hasPrefix("$result.") { return try valueAt(result, "$." + path.dropFirst("$result.".count)) }
        if path.hasPrefix("$output.") { return try valueAt(output.json, "$." + path.dropFirst("$output.".count)) }
        return try valueAt(output.json, path)
    }

    /// acpx's `getByPath`: `$.` then keys split on `.`, each looked up in an object, or an
    /// array (an index, or its `length`) — undefined through anything else, a string
    /// included (`typeof current !== "object"`). A key JavaScript would find on the
    /// prototype (`constructor`) finds no scalar either way.
    private static func valueAt(_ root: WireJSON?, _ path: String) throws -> WireJSON? {
        guard path.hasPrefix("$.") else { throw RoutingError(message: "Unsupported JSON path: \(path)") }
        var current = root
        for key in path.dropFirst(2).split(separator: ".", omittingEmptySubsequences: false) {
            switch current {
            case .object?: current = current?[String(key)]
            case .array(let items)?:
                if let index = Int(key), String(index) == key, items.indices.contains(index) {
                    current = items[index]
                } else {
                    current = key == "length" ? .number(Double(items.count)) : nil
                }
            default:
                current = nil
            }
        }
        return current
    }

    /// `String(value)` for a string, number or boolean — `nil` for anything else.
    private static func scalarString(_ value: WireJSON) -> String? {
        switch value {
        case .string: return value.stringValue
        case .number(let number): return WireJSON.javaScriptString(for: number)
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }
}

extension WireJSON {
    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
