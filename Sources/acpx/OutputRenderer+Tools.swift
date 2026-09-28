import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

// The text mode's tool rendering — acpx's `renderToolUpdate` — split from `OutputRenderer.swift` to
// keep that file inside the 500-line limit.
extension OutputRenderer {
    // MARK: Tool state machine (mirrors renderToolUpdate)

    /// Merge an update into the state of tool `id` — kept under `key` when that is not the id's
    /// text — and render the tool when acpx would.
    func renderTool(
        id: String, key: String? = nil, title: String?, status: ToolCallStatus?, kind: ToolKind?,
        locations: [ToolCallLocation]?, rawInput: JSONValue?, rawOutput: JSONValue?,
        content: [ToolCallContent]?, clearing nulled: Set<String> = []
    ) {
        let key = key ?? id
        let state = toolStates[key] ?? {
            let created = ToolRenderState(id: id)
            toolStates[key] = created
            return created
        }()

        // acpx's `mergeToolTitle` / `mergeToolPayloadState`: a title that is not blank,
        // and each other member that was sent — `null` clearing it.
        if let title, !title.javaScriptTrimmed.isEmpty { state.title = title }
        if status != nil || nulled.contains("status") { state.status = status }
        if kind != nil || nulled.contains("kind") { state.kind = kind }
        if locations != nil || nulled.contains("locations") { state.locations = locations }
        if rawInput != nil || nulled.contains("rawInput") { state.rawInput = rawInput }
        if rawOutput != nil || nulled.contains("rawOutput") { state.rawOutput = rawOutput }
        if content != nil || nulled.contains("content") { state.content = content }

        let isFinal = state.status == .completed || state.status == .failed
        if isFinal {
            let signature = toolSignature(state)
            if signature != state.finalSignature {
                state.finalSignature = signature
                renderFinalToolState(state)
            }
            return
        }

        if state.startedPrinted { return }
        state.startedPrinted = true
        renderStartingToolState(state)
    }

    /// A tool update acpx's ACP SDK refuses — without a member its schema requires — rendered all
    /// the same, as acpx's formatter renders the wire message as it came (#175): whatever members it
    /// has, merged into the tool's state as they are. Its `toolCallId` is JavaScript's, shown as
    /// `String()` shows it: one without keys the one state of `undefined`, titled so until a title
    /// comes, and one that is no string is a tool of its own, as a `Map` keys it.
    func renderRefusedTool(_ payload: JSONValue) {
        guard case .object(let members) = payload else { return }
        let id = members["toolCallId"].map(Self.javaScriptText) ?? "undefined"
        let key: String = if case .string(let text)? = members["toolCallId"] { text } else { "\u{0}" + id }
        let nulled = Set(members.filter { $0.value == .null }.map(\.key))
        let title: String? = if case .string(let text)? = members["title"] { text } else { nil }
        renderTool(
            id: id, key: key, title: title,
            status: members["status"].flatMap(Self.openText).map(ToolCallStatus.init(rawValue:)),
            kind: members["kind"].flatMap(Self.openText).map(ToolKind.init(rawValue:)),
            locations: members["locations"].flatMap { try? $0.decoded([ToolCallLocation].self) },
            rawInput: members["rawInput"], rawOutput: members["rawOutput"],
            content: members["content"].flatMap { try? $0.decoded([ToolCallContent].self) }, clearing: nulled)
    }

    /// A member's value as JavaScript's `String()` shows it, `null` as none.
    private static func openText(_ value: JSONValue) -> String? {
        value == .null ? nil : javaScriptText(value)
    }

    /// `value` as JavaScript's `String()` shows it.
    private static func javaScriptText(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .integer(let number): return String(number)
        case .unsignedInteger(let number): return String(number)
        case .double(let number):
            return number == number.rounded() && abs(number) < 1e21 ? String(Int64(number)) : String(number)
        case .string(let text): return text
        case .array(let items): return items.map { $0 == .null ? "" : javaScriptText($0) }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    func renderStartingToolState(_ state: ToolRenderState) {
        beginSection()
        let title = state.title ?? state.id
        let label = state.status == .pending ? "pending" : "running"
        writeLine("\(bold("[tool]")) \(title) (\(colorStatus(label, state.status)))")
        if let input = ToolText.summarizeInput(state.rawInput) { writeLine("  input: \(input)") }
        if let files = ToolText.formatLocations(state.locations) { writeLine("  files: \(files)") }
    }

    func renderFinalToolState(_ state: ToolRenderState) {
        beginSection()
        let title = state.title ?? state.id
        let label = state.status == .failed ? "failed" : "completed"
        writeLine("\(bold("[tool]")) \(title) (\(colorStatus(label, state.status)))")
        if let kind = state.kind { writeLine("  kind: \(kind.rawValue)") }
        if let input = ToolText.summarizeInput(state.rawInput) { writeLine("  input: \(input)") }
        if let files = ToolText.formatLocations(state.locations) { writeLine("  files: \(files)") }
        if let output = renderedToolOutput(state) {
            writeLine("  output:")
            writeLine(indentBlock(limitOutputBlock(output), "    "))
        }
    }

    func renderedToolOutput(_ state: ToolRenderState) -> String? {
        if options.suppressReads, ToolText.isReadLike(title: state.title, kind: state.kind) {
            return SUPPRESSED_READ_OUTPUT
        }
        return ToolText.summarizeOutput(rawOutput: state.rawOutput, content: state.content)
    }

    func toolSignature(_ state: ToolRenderState) -> String {
        let parts: [String] = [
            state.title ?? "",
            state.status?.rawValue ?? "",
            state.kind?.rawValue ?? "",
            ToolText.summarizeInput(state.rawInput) ?? "",
            ToolText.formatLocations(state.locations) ?? "",
            renderedToolOutput(state) ?? ""
        ]
        return parts.joined(separator: "\u{1F}")
    }
}

final class ToolRenderState {
    let id: String
    var title: String?
    var status: ToolCallStatus?
    var kind: ToolKind?
    var locations: [ToolCallLocation]?
    var rawInput: JSONValue?
    var rawOutput: JSONValue?
    var content: [ToolCallContent]?
    var startedPrinted = false
    var finalSignature: String?
    init(id: String) { self.id = id }
}
