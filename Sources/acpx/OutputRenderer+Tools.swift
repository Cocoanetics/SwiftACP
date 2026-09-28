import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

// The text mode's tool rendering — acpx's `renderToolUpdate` — split from `OutputRenderer.swift` to
// keep that file inside the 500-line limit.
extension OutputRenderer {
    // MARK: Tool state machine (mirrors renderToolUpdate)

    /// Merge an update into the state of tool `id` — kept under `key`, when that is not the id
    /// as a string — and render the tool when acpx would.
    func renderTool(
        id: String, key: ToolKey? = nil, title: String?, status: ToolCallStatus?, kind: ToolKind?,
        locations: [ToolCallLocation]?, rawInput: JSONValue?, rawOutput: JSONValue?,
        content: [ToolCallContent]?, kindIsText: Bool = true, clearing nulled: Set<String> = []
    ) {
        let key = key ?? .string(Array(id.utf16))
        let state = toolStates[key] ?? {
            let created = ToolRenderState(id: id)
            toolStates[key] = created
            return created
        }()

        // acpx's `mergeToolTitle` / `mergeToolPayloadState`: a title that is not blank,
        // and each other member that was sent — `null` clearing it.
        if let title, !title.javaScriptTrimmed.isEmpty { state.title = title }
        if status != nil || nulled.contains("status") { state.status = status }
        if kind != nil || nulled.contains("kind") {
            state.kind = kind
            state.kindIsText = kindIsText
        }
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
    /// has, merged into the tool's state as they are. Its `toolCallId` is JavaScript's: shown as
    /// `String()` shows it, and keyed as a `Map` keys it (``ToolKey``) — one without is the one
    /// state of `undefined`, titled so until a title comes.
    func renderRefusedTool(_ payload: JSONValue) {
        guard case .object(let members) = payload else { return }
        let toolCallId = members["toolCallId"]
        let id = toolCallId.map(Self.javaScriptText) ?? "undefined"
        let key: ToolKey = switch toolCallId {
        case nil: .undefined
        case .null?: .null
        case .bool(let flag)?: .bool(flag)
        case .string(let text)?: .string(Array(text.utf16))
        case .integer?, .unsignedInteger?, .double?: .number(id)
        case .array?, .object?: .object(UUID())
        }
        var nulled = Set(members.filter { $0.value == .null }.map(\.key))
        let title: String? = if case .string(let text)? = members["title"] { text } else { nil }
        // A status that is no string is none of the statuses, as acpx's strict comparisons find
        // none: the tool runs, as with none at all (#270 review). `["completed"]` is no finished tool.
        var status: ToolCallStatus?
        switch members["status"] {
        case .string(let text)?: status = ToolCallStatus(rawValue: text)
        case .some: nulled.insert("status")
        case nil: break
        }
        // A kind that is no string shows as its text, but is no kind that text names (#270 review).
        let kind = members["kind"].flatMap { $0 == .null ? nil : ToolKind(rawValue: Self.javaScriptText($0)) }
        let kindIsText: Bool = if case .string? = members["kind"] { true } else { false }
        renderTool(
            id: id, key: key, title: title, status: status, kind: kind,
            locations: members["locations"].flatMap { Self.entries($0, as: ToolCallLocation.self) },
            rawInput: members["rawInput"], rawOutput: members["rawOutput"],
            content: members["content"].flatMap { Self.entries($0, as: ToolCallContent.self) },
            kindIsText: kindIsText, clearing: nulled)
    }

    /// A list member's entries that read as `T`, each on its own — as the ACP schema reads a tool's
    /// lists, and as acpx's formatter shows only the entries it can: a malformed one leaves the
    /// others (#270 review). One that is no list is an empty one, replacing what came before as
    /// acpx's does; `null` is none, clearing it.
    private static func entries<T: Decodable>(_ value: JSONValue, as type: T.Type) -> [T]? {
        switch value {
        case .null: return nil
        case .array(let items): return items.compactMap { try? $0.decoded(T.self) }
        default: return []
        }
    }

    /// `value` as JavaScript's `String()` shows it.
    private static func javaScriptText(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        // A number as JavaScript has it — every JSON number a double — and shows it (#270 review).
        case .integer(let number): return WireJSON.javaScriptString(for: Double(number))
        case .unsignedInteger(let number): return WireJSON.javaScriptString(for: Double(number))
        case .double(let number): return WireJSON.javaScriptString(for: number)
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
        if options.suppressReads, ToolText.isReadLike(title: state.title, kind: state.kindIsText ? state.kind : nil) {
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

/// A tool's key among the text renderer's tool states: a `toolCallId` as a JavaScript `Map` keys
/// it (SameValueZero), for an update acpx's SDK refuses can name its tool with any JSON value
/// (#270 review).
enum ToolKey: Hashable {
    /// A string, by its UTF-16 code units, as JavaScript compares strings: `"é"` and `"e\u{301}"`,
    /// one to Swift's `String`, are two tools (#270 review).
    case string([UInt16])
    case undefined
    case null
    case bool(Bool)
    /// A number, by the text JavaScript shows it as: `5` and `5.0` are one number, as `0` and `-0`
    /// are.
    case number(String)
    /// An object or an array, a new one with each update — no other update's key.
    case object(UUID)
}

final class ToolRenderState {
    let id: String
    var title: String?
    var status: ToolCallStatus?
    var kind: ToolKind?
    /// Whether ``kind`` came as a string: one that did not shows as its text, but names no kind.
    var kindIsText = true
    var locations: [ToolCallLocation]?
    var rawInput: JSONValue?
    var rawOutput: JSONValue?
    var content: [ToolCallContent]?
    var startedPrinted = false
    var finalSignature: String?
    init(id: String) { self.id = id }
}
