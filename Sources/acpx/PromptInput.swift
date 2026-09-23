import Foundation
import SwiftACP

/// Resolves a command's prompt from positional words, `--file` (`-` = stdin), or
/// piped stdin, into the ACP content blocks the turn will send.
///
/// Mirrors npm acpx's `readPromptInput` / `parsePromptSource`, including the
/// structured form: a `--file` or stdin source that starts with `[` is parsed as a
/// JSON array of ACP content blocks, so a prompt can carry an image or hand over a
/// file. Positional words are always plain text — only a file or a pipe can be
/// structured — and when both are given the words become a trailing text block.
///
/// A source that starts with `[` but is not valid JSON falls back to being the
/// prompt text, matching upstream: a prompt may legitimately open with a bracket.
/// One that *is* a JSON array but holds something other than valid blocks is an
/// error naming the offending index, rather than being silently sent as text.
enum PromptInputResolver {
    /// - Returns: the turn's blocks — never empty.
    static func resolve(words: [String], file: String?, cwd: String) throws -> [PromptBlock] {
        let appended = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        if let file {
            let source: String
            if file == "-" {
                source = readStdin()
            } else {
                let path = file.hasPrefix("/") ? file : cwd + "/" + file
                source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            }
            var blocks = try parse(source)
            if !appended.isEmpty { blocks.append(.text(appended)) }
            guard !blocks.isEmpty else { throw InvalidArgumentError("Prompt from --file is empty") }
            return blocks
        }

        if !appended.isEmpty { return [.text(appended)] }

        guard isatty(fileno(stdin)) == 0 else {
            throw InvalidArgumentError("Prompt is required (pass as argument, --file, or pipe via stdin)")
        }
        let blocks = try parse(readStdin())
        guard !blocks.isEmpty else { throw InvalidArgumentError("Prompt from stdin is empty") }
        return blocks
    }

    /// npm acpx's `parsePromptSource`: structured blocks when the source is a JSON
    /// array, one text block otherwise, nothing when it is blank.
    static func parse(_ source: String) throws -> [PromptBlock] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let structured = try structuredBlocks(trimmed) { return structured }
        return trimmed.isEmpty ? [] : [.text(trimmed)]
    }

    /// Parses `source` as a JSON array of ACP content blocks, or nil when it is not
    /// one and should be treated as text.
    private static func structuredBlocks(_ source: String) throws -> [PromptBlock]? {
        guard source.hasPrefix("[") else { return nil }
        guard let data = source.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let elements = parsed as? [Any]
        else { return nil }

        // An empty array is a valid parse of an empty prompt; the caller reports it.
        guard !elements.isEmpty else { return [] }

        let decoder = JSONDecoder()
        let blocks = try elements.enumerated().map { index, element -> PromptBlock in
            guard let object = element as? [String: Any], object["type"] is String,
                  let elementData = try? JSONSerialization.data(withJSONObject: object),
                  let block = try? decoder.decode(PromptBlock.self, from: elementData)
            else {
                throw InvalidArgumentError(
                    "prompt[\(index)]: must be an ACP content block object with a string type")
            }
            return block
        }
        // Validate at parse time so a bad block is a usage error naming the offending
        // index — the way upstream reports one — rather than a failure at dispatch.
        // No request cap here: `exec` and `compare` talk to the agent directly, and
        // the daemon applies its own transport limit to the turns that go through it.
        do {
            _ = try PromptBlock.contentBlocks(text: "", blocks: blocks, requestLimit: nil)
        } catch let error as PromptBlockError {
            throw InvalidArgumentError(error.errorDescription ?? "\(error)")
        }
        return blocks
    }

    private static func readStdin() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
