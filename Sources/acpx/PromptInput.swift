import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// Resolves a command's prompt from positional words, `--file` (`-` = stdin), or
/// piped stdin, into the ACP content blocks the turn will send — npm acpx's
/// `readPromptInput` (`src/cli/prompt-input.ts`).
///
/// A `--file` or stdin source that starts with `[` and is a JSON array is a structured
/// prompt, checked and kept as written (``PromptContent``): a prompt can carry an image
/// or hand over a file. Positional words are always plain text — only a file or a pipe
/// can be structured — and when both are given the words become a trailing text block.
/// A source that starts with `[` but is not JSON is the prompt's text: a prompt may
/// open with a bracket. A structured prompt with a block acpx does not take is a usage
/// error in acpx's words.
enum PromptInputResolver {
    /// - Returns: the turn's content blocks as written — never empty.
    static func resolve(words: [String], file: String?, cwd: String) throws -> [WireJSON] {
        let text = words.joined(separator: " ")
        do {
            if let file {
                let source = file == "-" ? readStdin() : try read(file, cwd: cwd)
                let blocks = try PromptContent.parse(source, appending: text)
                guard !blocks.isEmpty else { throw InvalidArgumentError("Prompt from --file is empty") }
                return blocks
            }

            let joined = text.javaScriptTrimmed
            if !joined.isEmpty { return [PromptContent.textBlock(joined)] }

            guard isatty(fileno(stdin)) == 0 else {
                throw InvalidArgumentError("Prompt is required (pass as argument, --file, or pipe via stdin)")
            }
            let blocks = try PromptContent.parse(readStdin())
            guard !blocks.isEmpty else { throw InvalidArgumentError("Prompt from stdin is empty") }
            return blocks
        } catch let invalid as PromptContent.ValidationError {
            throw InvalidArgumentError(invalid.message)
        }
    }

    /// The blocks as the ACP content a caller talking to the agent itself sends. An
    /// unpaired surrogate, which acpx passes on escaped, goes as U+FFFD: no Swift string
    /// holds one.
    static func contentBlocks(_ blocks: [WireJSON]) throws -> [ContentBlock] {
        try blocks.enumerated().map { index, block in
            do {
                return try JSONDecoder().decode(ContentBlock.self, from: data(block))
            } catch {
                throw InvalidArgumentError("prompt[\(index)] cannot be sent as an ACP content block: \(error)")
            }
        }
    }

    /// The blocks as JSON values, for the daemon's `runPrompt`.
    static func jsonValues(_ blocks: [WireJSON]) throws -> [JSONValue] {
        try blocks.map { try JSONDecoder().decode(JSONValue.self, from: data($0)) }
    }

    /// A block as JSON text Foundation reads.
    private static func data(_ block: WireJSON) -> Data {
        Data(block.replacingLoneSurrogates().stringified.utf8)
    }

    /// Node's `fs.readFile(path.resolve(cwd, file), "utf8")`: the file's bytes as UTF-8,
    /// a bad sequence becoming U+FFFD; a file that cannot be read fails in Node's words.
    private static func read(_ file: String, cwd: String) throws -> String {
        let path = URL(fileURLWithPath: file, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
            .standardizedFileURL.path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw FileReadError(message: "EISDIR: illegal operation on a directory, read")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            let reason = FileManager.default.fileExists(atPath: path)
                ? "EACCES: permission denied" : "ENOENT: no such file or directory"
            throw FileReadError(message: "\(reason), open '\(path)'")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Node's `text(process.stdin)`: all of it, as UTF-8.
    private static func readStdin() -> String {
        String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A prompt file Node could not read, in its words — acpx reports it as a runtime
    /// failure.
    struct FileReadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
