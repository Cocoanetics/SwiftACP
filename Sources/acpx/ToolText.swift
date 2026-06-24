import Foundation
import JSONFoundation
import SwiftACP

private let MAX_INLINE_CHARS = 220
private let MAX_LOCATION_ITEMS = 5
private let OUTPUT_PRIORITY_KEYS = [
    "stdout", "stderr", "output", "content", "text", "message", "result", "response", "value"
]

/// String summaries of tool input/output/locations — a direct port of the
/// helper functions in acpx's `src/cli/output/output.ts`.
enum ToolText {
    // MARK: Input

    static func summarizeInput(_ rawInput: JSONValue?) -> String? {
        guard let rawInput else { return nil }
        switch rawInput {
        case .null: return nil
        case .string(let value): return toInline(value)
        case .integer(let value): return toInline(String(value))
        case .unsignedInteger(let value): return toInline(String(value))
        case .double(let value): return toInline(String(value))
        case .bool(let value): return toInline(String(value))
        case .object(let fields): return summarizeInputRecord(fields) ?? summarizeInputJSON(rawInput)
        case .array: return summarizeInputJSON(rawInput)
        }
    }

    private static func summarizeInputRecord(_ fields: [String: JSONValue]) -> String? {
        if let command = firstString(fields, ["command", "cmd", "program"]) {
            let args = firstStringArray(fields, ["args", "arguments"]) ?? []
            return toInline(([command] + args).joined(separator: " "))
        }
        let location = firstString(fields, ["path", "file", "filePath", "filepath", "target", "uri", "url"])
        let query = firstString(fields, ["query", "pattern", "text", "search"])
        if let value = location ?? query { return toInline(value) }
        return nil
    }

    private static func summarizeInputJSON(_ value: JSONValue) -> String? {
        guard let json = jsonString(value, pretty: false) else { return nil }
        return toInline(json)
    }

    // MARK: Output

    static func summarizeOutput(rawOutput: JSONValue?, content: [ToolCallContent]?) -> String? {
        let fromRaw = extractOutputText(rawOutput)
        let fromContent = summarizeContent(content)
        let fragments = dedupe(
            [fromRaw, fromContent]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        return fragments.isEmpty ? nil : fragments.joined(separator: "\n\n")
    }

    private static func summarizeContent(_ content: [ToolCallContent]?) -> String? {
        guard let content, !content.isEmpty else { return nil }
        let fragments = content.compactMap(summarizeContentEntry)
        let unique = dedupe(fragments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return unique.isEmpty ? nil : unique.joined(separator: "\n\n")
    }

    private static func summarizeContentEntry(_ entry: ToolCallContent) -> String? {
        switch entry {
        case .content(let block):
            guard let text = textFromContentBlock(block),
                !text.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return trimTrailing(text)
        case .diff(let diff):
            return summarizeDiff(path: diff.path, oldText: diff.oldText, newText: diff.newText)
        case .terminal(let terminalId):
            return "[terminal] \(terminalId)"
        case .other:
            return nil
        }
    }

    private static func textFromContentBlock(_ content: ContentBlock) -> String? {
        switch content {
        case .text(let text): return text.text
        case .resourceLink(let link): return link.title ?? link.name
        case .resource(let resource):
            if let text = resource.resource.text { return text }
            let mime = resource.resource.mimeType.map { " (\($0))" } ?? ""
            return "[resource] \(resource.resource.uri)\(mime)"
        case .image(let image): return "[image] \(image.mimeType)"
        case .audio(let audio): return "[audio] \(audio.mimeType)"
        }
    }

    private static func extractOutputText(_ value: JSONValue?, _ depth: Int = 0) -> String? {
        guard let value else { return nil }
        switch value {
        case .null: return nil
        case .string(let text):
            let trimmed = trimTrailing(text)
            return trimmed.isEmpty ? nil : trimmed
        case .integer(let value): return String(value)
        case .unsignedInteger(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return String(value)
        case .array(let entries):
            if depth >= 4 { return nil }
            let parts = entries.compactMap { extractOutputText($0, depth + 1) }
            return parts.isEmpty ? nil : dedupe(parts).joined(separator: "\n")
        case .object(let fields):
            if depth >= 4 { return nil }
            var preferred: [String] = []
            for key in OUTPUT_PRIORITY_KEYS {
                if let entry = fields[key], let text = extractOutputText(entry, depth + 1) {
                    preferred.append(text)
                }
            }
            let unique = dedupe(preferred)
            if !unique.isEmpty { return unique.joined(separator: "\n") }
            let json = jsonString(value, pretty: true)
            return (json == nil || json == "{}") ? nil : json
        }
    }

    static func summarizeDiff(path: String, oldText: String?, newText: String) -> String {
        let oldLines = oldText.map { $0.components(separatedBy: "\n").count } ?? 0
        let newLines = newText.components(separatedBy: "\n").count
        let delta = newLines - oldLines
        if delta == 0 { return "diff \(path) (line count unchanged)" }
        return "diff \(path) (\(delta > 0 ? "+" : "")\(delta) lines)"
    }

    // MARK: Locations

    static func formatLocations(_ locations: [ToolCallLocation]?) -> String? {
        guard let locations, !locations.isEmpty else { return nil }
        var seen = Set<String>()
        var unique: [String] = []
        for location in locations {
            if let formatted = formatLocation(location), seen.insert(formatted).inserted {
                unique.append(formatted)
            }
        }
        guard !unique.isEmpty else { return nil }
        let visible = Array(unique.prefix(MAX_LOCATION_ITEMS))
        let hidden = unique.count - visible.count
        return hidden <= 0
            ? visible.joined(separator: ", ")
            : visible.joined(separator: ", ") + ", +\(hidden) more"
    }

    private static func formatLocation(_ location: ToolCallLocation) -> String? {
        let path = location.path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        if let line = location.line, line > 0 { return "\(path):\(max(1, line))" }
        return path
    }

    // MARK: Read-like classification (read-suppression.ts)

    static func isReadLike(title: String?, kind: ToolKind?) -> Bool {
        if kind?.rawValue.trimmingCharacters(in: .whitespaces).lowercased() == "read" { return true }
        guard let head = title?.lowercased().split(separator: ":", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces), !head.isEmpty
        else { return false }
        return ["read", "cat", "open", "view"].contains { head.contains($0) }
    }

    // MARK: Small helpers (port of output.ts)

    private static func firstString(_ fields: [String: JSONValue], _ keys: [String]) -> String? {
        for key in keys {
            if case .string(let value)? = fields[key] {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func firstStringArray(_ fields: [String: JSONValue], _ keys: [String]) -> [String]? {
        for key in keys {
            if case .array(let array)? = fields[key] {
                let entries = array.compactMap { element -> String? in
                    guard case .string(let value) = element else { return nil }
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    return trimmed.isEmpty ? nil : trimmed
                }
                if !entries.isEmpty { return entries }
            }
        }
        return nil
    }

    private static func toInline(_ value: String, _ maxChars: Int = MAX_INLINE_CHARS) -> String {
        let collapsed = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if collapsed.count <= maxChars { return collapsed }
        if maxChars <= 3 { return String(collapsed.prefix(maxChars)) }
        return String(collapsed.prefix(maxChars - 3)) + "..."
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func trimTrailing(_ value: String) -> String {
        var slice = Substring(value)
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return String(slice)
    }

    private static func jsonString(_ value: JSONValue, pretty: Bool) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }
}
