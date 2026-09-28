import Foundation
import JSONFoundation
import SwiftACP

// A tool call's `tool_call` and `tool_call_update`s folded into a `ToolUse` block and its
// `tool_results` entry (acpx's `applyToolCallUpdate`). Split from `ConversationModel.swift`.
extension ConversationModel {
    // MARK: - Tool calls → ToolUse content + tool_results

    /// The subset of fields acpx reads from a `tool_call` / `tool_call_update`,
    /// with presence flags (it distinguishes "field absent" from "field present"), and
    /// `rawInput` and `rawOutput` as the agent sent them, when known (#119).
    struct ToolFields {
        let id: String
        let title: String?
        let kind: ToolKind?
        let status: ToolCallStatus?
        let hasRawInput: Bool
        let rawInput: JSONValue?
        let hasRawOutput: Bool
        let rawOutput: JSONValue?
        var rawInputWire: WireJSON?
        var rawOutputWire: WireJSON?

        // acpx's ACP SDK reads a kind or a status it doesn't know as none, so acpx never
        // sees one.
        init(_ call: ToolCall, raw: WireJSON? = nil) {
            id = call.toolCallId
            title = call.title
            kind = call.kind.flatMap { $0.reachesACPX ? $0 : nil }
            status = call.status.flatMap { $0.reachesACPX ? $0 : nil }
            hasRawInput = call.rawInput != nil
            rawInput = call.rawInput
            hasRawOutput = call.rawOutput != nil
            rawOutput = call.rawOutput
            (rawInputWire, rawOutputWire) = Self.wireForms(in: raw, input: rawInput, output: rawOutput)
        }

        init(_ update: ToolCallUpdate, raw: WireJSON? = nil) {
            id = update.toolCallId
            title = update.title
            kind = update.kind.flatMap { $0.reachesACPX ? $0 : nil }
            status = update.status.flatMap { $0.reachesACPX ? $0 : nil }
            hasRawInput = update.rawInput != nil
            rawInput = update.rawInput
            hasRawOutput = update.rawOutput != nil
            rawOutput = update.rawOutput
            (rawInputWire, rawOutputWire) = Self.wireForms(in: raw, input: rawInput, output: rawOutput)
        }

        /// `raw`'s `rawInput` and `rawOutput`, each when it is an object or an array — whose
        /// order the value lost — and holds what was read.
        static func wireForms(
            in raw: WireJSON?, input: JSONValue?, output: JSONValue?
        ) -> (input: WireJSON?, output: WireJSON?) {
            func form(_ key: String, _ value: JSONValue?) -> WireJSON? {
                guard let value, let wire = raw?[key] else { return nil }
                switch wire {
                case .object, .array: return wire.holds(value) ? wire : nil
                default: return nil
                }
            }
            return (form("rawInput", input), form("rawOutput", output))
        }

        var hasResultPatch: Bool {
            hasRawOutput || status != nil || title != nil || kind != nil
        }
    }

    static func applyToolCall(_ agent: inout SessionAgentMessage, fields: ToolFields) {
        let index = ensureToolUseIndex(&agent, id: fields.id)
        guard case .toolUse(var tool) = agent.content[index] else { return }

        // Identity: prefer the title, else fall back to the kind.
        if let title = trimmedString(fields.title) {
            tool.name = title
        }
        if let kind = trimmedString(fields.kind?.rawValue), tool.name.isEmpty || tool.name == "tool_call" {
            tool.name = kind
        }
        // Input.
        if fields.hasRawInput {
            tool.input = fields.rawInput
            tool.inputWire = fields.rawInputWire
            tool.rawInput = toRawInput(fields.rawInput, wire: fields.rawInputWire)
        }
        // Status → whether the input is complete.
        if let status = fields.status {
            tool.isInputComplete = statusIndicatesComplete(status.rawValue)
        }
        agent.content[index] = .toolUse(tool)

        // Result (output) goes into tool_results, keyed by id.
        if fields.hasResultPatch {
            // No `status` in this patch means "unchanged", not "not an error" — a
            // recorded failure must survive a later output-only update (acpx:
            // `is_error: status === undefined ? undefined : statusIndicatesError(status)`).
            let isError = fields.status.map { statusIndicatesError($0.rawValue) }
            // `JSONValue?.none`, not a bare `nil`: `JSONValue` is `ExpressibleByNilLiteral`,
            // so `nil` here unifies as `JSONValue.null` and a status-only patch would
            // overwrite recorded output with null instead of keeping it.
            let content: JSONValue? =
                fields.hasRawOutput
                ? toToolResultContent(fields.rawOutput, wire: fields.rawOutputWire) : JSONValue?.none
            upsertToolResult(
                &agent, id: fields.id, toolName: tool.name, isError: isError,
                content: content, output: fields.hasRawOutput ? fields.rawOutput : nil,
                outputWire: fields.hasRawOutput ? fields.rawOutputWire : nil)
        }
    }

    /// Index of the `ToolUse` block with `id`, creating one if absent.
    private static func ensureToolUseIndex(_ agent: inout SessionAgentMessage, id: String) -> Int {
        for (index, content) in agent.content.enumerated() {
            if case .toolUse(let tool) = content, tool.id == id { return index }
        }
        agent.content.append(
            .toolUse(
                SessionToolUse(
                    id: id, name: "tool_call", rawInput: "{}", input: .object([:]),
                    isInputComplete: false, thoughtSignature: .null)))
        return agent.content.count - 1
    }

    private static func upsertToolResult(
        _ agent: inout SessionAgentMessage, id: String, toolName: String, isError: Bool?,
        content: JSONValue?, output: JSONValue?, outputWire: WireJSON?
    ) {
        let existing = agent.toolResults[id]
        agent.toolResults[id] = SessionToolResult(
            toolUseId: id,
            toolName: toolName,
            isError: isError ?? existing?.isError ?? false,
            content: content ?? existing?.content ?? .object(["Text": .string("")]),
            output: output ?? existing?.output,
            outputWire: output == nil ? existing?.outputWire : outputWire)
    }

    private static func trimmedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func statusIndicatesComplete(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        return ["complete", "done", "success", "failed", "error", "cancel"].contains {
            status.contains($0)
        }
    }

    private static func statusIndicatesError(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        return status.contains("fail") || status.contains("error")
    }

    /// `toRawInput` — a tool's input as a trimmed JSON string: `JSON.stringify` of it as the
    /// agent sent it (`wire`), when known.
    private static func toRawInput(_ value: JSONValue?, wire: WireJSON?) -> String {
        guard let value, value != .null else { return "{}" }
        if case .string(let text) = value { return trimRuntimeText(text, maxRuntimeToolIOChars) }
        return trimRuntimeText(wire?.stringified ?? javaScriptJSON(value) ?? "{}", maxRuntimeToolIOChars)
    }

    /// `toToolResultContent` — a tool's output as `{ "Text": <trimmed string> }`: `JSON.stringify`
    /// of it as the agent sent it (`wire`), when known.
    private static func toToolResultContent(_ value: JSONValue?, wire: WireJSON?) -> JSONValue {
        guard let value, value != .null else { return .object(["Text": .string("")]) }
        if case .string(let text) = value {
            return .object(["Text": .string(trimRuntimeText(text, maxRuntimeToolIOChars))])
        }
        let json = wire?.stringified ?? javaScriptJSON(value) ?? "[Unserializable value]"
        return .object(["Text": .string(trimRuntimeText(json, maxRuntimeToolIOChars))])
    }

    /// `JSON.stringify(value)`, with its escapes and number forms. The members come
    /// sorted: the order the agent sent them in is gone once the value is a `JSONValue`,
    /// where no wire form of it was kept.
    private static func javaScriptJSON(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { WireJSON(parsing: $0) }?.stringified
    }
}
