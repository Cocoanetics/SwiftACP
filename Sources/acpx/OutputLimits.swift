import Foundation

// Ports the output-trimming helpers of acpx's `src/cli/output/output.ts`:
// `limitOutputBlock` (cap a tool's output at 28 lines / 2000 chars) and the
// line-ending/truncation utilities it shares with the renderer's thought
// buffering. Pure string functions — no rendering state.

private let MAX_OUTPUT_CHARS = 2000
private let MAX_OUTPUT_LINES = 28

/// Port of acpx's `limitOutputBlock`.
func limitOutputBlock(_ value: String) -> String {
    let normalized = normalizeLineEndings(value).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return "" }
    var lines = normalized.components(separatedBy: "\n")
    let hidden = lines.count - MAX_OUTPUT_LINES
    if hidden > 0 {
        lines = Array(lines.prefix(MAX_OUTPUT_LINES))
    }
    var result = lines.joined(separator: "\n")
    if hidden > 0 { result += "\n... (\(hidden) more lines)" }
    if result.count > MAX_OUTPUT_CHARS {
        result = String(result.prefix(MAX_OUTPUT_CHARS - 3)) + "..."
    }
    return result
}

func indentBlock(_ value: String, _ prefix: String) -> String {
    value.components(separatedBy: "\n").map { prefix + $0 }.joined(separator: "\n")
}

func normalizeLineEndings(_ value: String) -> String {
    value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

func truncate(_ value: String, _ maxChars: Int) -> String {
    if value.count <= maxChars { return value }
    if maxChars <= 3 { return String(value.prefix(maxChars)) }
    return String(value.prefix(maxChars - 3)) + "..."
}
