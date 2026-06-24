import ACPXCore
import Foundation
import SwiftACP

// MARK: - Help model

/// One `Options:` row: the left-hand term (e.g. `-s, --session <name>`) and its
/// description. The auto `-h, --help` row is appended by the renderer, never
/// listed here.
struct HelpOption {
    let term: String
    let desc: String
    init(_ term: String, _ desc: String) {
        self.term = term
        self.desc = desc
    }
}

/// One `Arguments:` row. `term` is the bare name shown in the Arguments section
/// (e.g. `prompt`); `usage` is how it appears in the usage line (e.g.
/// `[prompt...]`, `<mode>`).
struct HelpArgument {
    let term: String
    let usage: String
    let desc: String
    init(_ term: String, _ usage: String, _ desc: String) {
        self.term = term
        self.usage = usage
        self.desc = desc
    }
}

/// One `Commands:` row: the subcommand term (e.g. `exec [options] [prompt...]`)
/// and its description.
struct HelpSubcommand {
    let term: String
    let desc: String
    init(_ term: String, _ desc: String) {
        self.term = term
        self.desc = desc
    }
}

/// A single `--help` screen, rendered to match commander.js 15's layout.
struct HelpScreen {
    var usagePath: String // "" for root, else e.g. "exec", "sessions list", "codex exec"
    var description: String
    var arguments: [HelpArgument] = []
    var options: [HelpOption] = []
    var subcommands: [HelpSubcommand] = []
    var after: String? // trailing free-form block (root "Examples:")
}

// MARK: - Renderer (faithful to commander.js 15 Help)

/// Reproduces commander.js 15's help layout byte-for-byte: a single term column
/// padded to the longest term across Arguments/Options/Commands, descriptions
/// wrapped at 80 columns via `boxWrap`, and the `minWidthToWrap` short-circuit
/// that leaves wide-term screens (like the root) unwrapped.
enum HelpRenderer {
    private static let helpRow = HelpOption("-h, --help", "display help for command")

    static func render(_ screen: HelpScreen) -> String {
        var lines: [String] = []

        // Usage line.
        var usage = "Usage: acpx"
        if !screen.usagePath.isEmpty { usage += " " + screen.usagePath }
        usage += " [options]"
        if !screen.subcommands.isEmpty { usage += " [command]" }
        let argUsage = screen.arguments.map(\.usage).joined(separator: " ")
        if !argUsage.isEmpty { usage += " " + argUsage }
        lines.append(usage)
        lines.append("")
        lines.append(screen.description)

        // commander pads every term to the widest term across all three groups.
        var terms = screen.arguments.map(\.term)
        terms += screen.options.map(\.term)
        terms.append(helpRow.term)
        terms += screen.subcommands.map(\.term)
        let termWidth = terms.map(\.count).max() ?? 0

        if !screen.arguments.isEmpty {
            lines.append("")
            lines.append("Arguments:")
            for arg in screen.arguments { lines.append(formatItem(arg.term, termWidth, arg.desc)) }
        }

        lines.append("")
        lines.append("Options:")
        for opt in screen.options { lines.append(formatItem(opt.term, termWidth, opt.desc)) }
        lines.append(formatItem(helpRow.term, termWidth, helpRow.desc))

        if !screen.subcommands.isEmpty {
            lines.append("")
            lines.append("Commands:")
            for sub in screen.subcommands { lines.append(formatItem(sub.term, termWidth, sub.desc)) }
        }

        var output = lines.joined(separator: "\n")
        if let after = screen.after { output += "\n\n" + after }
        return output + "\n"
    }

    /// commander `Help.formatItem`: pad the term, wrap the description, and indent
    /// continuation lines under the description column.
    static func formatItem(_ term: String, _ termWidth: Int, _ description: String) -> String {
        let itemIndent = "  "
        if description.isEmpty { return itemIndent + term }

        let paddedTerm =
            term.count >= termWidth
            ? term : term + String(repeating: " ", count: termWidth - term.count)
        let spacerWidth = 2
        let helpWidth = 80
        let remainingWidth = helpWidth - termWidth - spacerWidth - itemIndent.count

        let formattedDescription: String
        if remainingWidth < minWidthToWrap || preformatted(description) {
            formattedDescription = description
        } else {
            let wrapped = boxWrap(description, remainingWidth)
            formattedDescription = wrapped.replacingOccurrences(
                of: "\n", with: "\n" + String(repeating: " ", count: termWidth + spacerWidth))
        }

        let body = itemIndent + paddedTerm + String(repeating: " ", count: spacerWidth) + formattedDescription
        return body.replacingOccurrences(of: "\n", with: "\n" + itemIndent)
    }

    private static let minWidthToWrap = 40

    /// commander `Help.preformatted`: a newline followed by a space/tab means the
    /// text is already manually laid out, so wrapping is skipped.
    static func preformatted(_ str: String) -> Bool {
        var index = str.startIndex
        while let newline = str.range(of: "\n", range: index ..< str.endIndex) {
            let after = newline.upperBound
            if after < str.endIndex, str[after] == " " || str[after] == "\t" { return true }
            index = newline.upperBound
        }
        return false
    }

    /// commander `Help.boxWrap`: greedy word wrap where each "chunk" carries its
    /// leading whitespace, accumulated while `sum + chunkWidth <= width`.
    static func boxWrap(_ str: String, _ width: Int) -> String {
        if width < minWidthToWrap { return str }

        var wrappedLines: [String] = []
        for rawLine in str.components(separatedBy: "\n") {
            let chunks = chunks(of: rawLine)
            guard let first = chunks.first else {
                wrappedLines.append("")
                continue
            }
            var sumChunks = [first]
            var sumWidth = first.count
            for chunk in chunks.dropFirst() {
                if sumWidth + chunk.count <= width {
                    sumChunks.append(chunk)
                    sumWidth += chunk.count
                } else {
                    wrappedLines.append(sumChunks.joined())
                    let next = String(chunk.drop { $0 == " " || $0 == "\t" }) // trim break space
                    sumChunks = [next]
                    sumWidth = next.count
                }
            }
            wrappedLines.append(sumChunks.joined())
        }
        return wrappedLines.joined(separator: "\n")
    }

    /// commander's `/[\s]*[^\s]+/g`: each chunk is optional leading whitespace
    /// followed by one run of non-whitespace. Trailing whitespace is dropped.
    private static func chunks(of line: String) -> [String] {
        var chunks: [String] = []
        var index = line.startIndex
        while index < line.endIndex {
            var wordStart = index
            while wordStart < line.endIndex, line[wordStart].isWhitespace {
                wordStart = line.index(after: wordStart)
            }
            var wordEnd = wordStart
            while wordEnd < line.endIndex, !line[wordEnd].isWhitespace {
                wordEnd = line.index(after: wordEnd)
            }
            if wordEnd == wordStart { break } // only trailing whitespace remained
            chunks.append(String(line[index ..< wordEnd]))
            index = wordEnd
        }
        return chunks
    }
}
