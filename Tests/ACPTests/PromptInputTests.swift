@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// The CLI's prompt input — npm acpx's `readPromptInput` and `parsePromptSource`
/// (#103). A `--file` or piped source that starts with `[` and is a JSON array is a
/// structured prompt: its blocks go to the agent as written, and the first block acpx
/// does not take is refused in acpx's words. Each case below is what acpx 0.19.1 made
/// of the same file with `exec --file`.
struct PromptInputTests {
    /// What the source came to: the blocks as JSON text, or acpx's refusal.
    private func outcome(_ source: String) -> String {
        do {
            return try PromptContent.parse(source).map(\.stringified).joined(separator: ",")
        } catch let error as PromptContent.ValidationError {
            return "refused: " + error.message
        } catch {
            return "failed: \(error)"
        }
    }

    static let refusals: [(String, String)] = [
        ("[1]", "prompt[0] must be an ACP content block object"),
        ("[null]", "prompt[0] must be an ACP content block object"),
        ("[[]]", "prompt[0] must be an ACP content block object"),
        (#"[{"type":1}]"#, "prompt[0] must be an ACP content block object"),
        (#"[{"text":"x"}]"#, "prompt[0] must be an ACP content block object"),
        (#"[{"type":"video"}]"#, #"prompt[0] has unsupported content block type "video""#),
        (#"[{"type":"__proto__"}]"#, #"prompt[0] has unsupported content block type "__proto__""#),
        (#"[{"type":"te\"xt\u00e9"}]"#, #"prompt[0] has unsupported content block type "te\"xté""#),
        (#"[{"type":"text"}]"#, "prompt[0] text block must include a string text field"),
        (#"[{"type":"text","text":5}]"#, "prompt[0] text block must include a string text field"),
        (#"[{"type":"image","data":"aGk="}]"#, "prompt[0] image block must include a non-empty mimeType"),
        (#"[{"type":"image","mimeType":"  ","data":"aGk="}]"#,
         "prompt[0] image block must include a non-empty mimeType"),
        (#"[{"type":"image","mimeType":"text/plain","data":"aGk="}]"#,
         "prompt[0] image block mimeType must start with image/"),
        (#"[{"type":"image","mimeType":"image/","data":"aGk="}]"#,
         "prompt[0] image block mimeType must start with image/"),
        (#"[{"type":"image","mimeType":"image/png ","data":"aGk="}]"#,
         "prompt[0] image block mimeType must start with image/"),
        (#"[{"type":"image","mimeType":"image/png","data":""}]"#,
         "prompt[0] image block must include non-empty base64 data"),
        (#"[{"type":"image","mimeType":"image/png","data":"!!!!"}]"#,
         "prompt[0] image block data must be valid base64"),
        (#"[{"type":"image","mimeType":"image/png","data":"aGk"}]"#,
         "prompt[0] image block data must be valid base64"),
        (#"[{"type":"image","mimeType":"image/png","data":"a==="}]"#,
         "prompt[0] image block data must be valid base64"),
        (#"[{"type":"audio","mimeType":"image/png","data":"aGk="}]"#,
         "prompt[0] audio block mimeType must start with audio/"),
        (#"[{"type":"resource_link","name":"n"}]"#, "prompt[0] resource_link block must include a non-empty uri"),
        (#"[{"type":"resource_link","uri":"  ","name":"n"}]"#,
         "prompt[0] resource_link block must include a non-empty uri"),
        (#"[{"type":"resource_link","uri":"u","name":"n","title":5}]"#,
         "prompt[0] resource_link block title must be a string or null when present"),
        (#"[{"type":"resource_link","uri":"u"}]"#, "prompt[0] resource_link block must include a string name"),
        (#"[{"type":"resource_link","uri":"u","name":5}]"#, "prompt[0] resource_link block must include a string name"),
        (#"[{"type":"resource"}]"#, "prompt[0] resource block must include a resource object"),
        (#"[{"type":"resource","resource":"x"}]"#, "prompt[0] resource block must include a resource object"),
        (#"[{"type":"resource","resource":{"uri":"u"}}]"#,
         "prompt[0] resource block resource must include a non-empty uri and a string text or blob field"),
        (#"[{"type":"resource","resource":{"uri":"","text":"t"}}]"#,
         "prompt[0] resource block resource must include a non-empty uri and a string text or blob field"),
        (#"[1, {"type":"video"}]"#, "prompt[0] must be an ACP content block object"),
        (#"[{"type":"text","text":"ok"},{"type":"image","mimeType":"x","data":"aGk="}]"#,
         "prompt[1] image block mimeType must start with image/")
    ]

    @Test(arguments: refusals)
    func aBlockAcpxDoesNotTakeIsRefusedInItsWords(source: String, message: String) {
        #expect(outcome(source) == "refused: " + message)
    }

    /// acpx checks what a block's type needs and no more: any `image/*` subtype in any
    /// case, a `blob` resource, a `null` title — and the block goes on as written, extra
    /// fields and all. A duplicate key keeps its first place and its last value, as
    /// `JSON.parse` has it.
    static let takenAsWritten: [(String, String)] = [
        (#"[{"type":"image","mimeType":"IMAGE/PNG","data":"aGk="}]"#,
         #"{"type":"image","mimeType":"IMAGE/PNG","data":"aGk="}"#),
        (#"[{"type":"image","mimeType":"image/bmp","data":"aGk="}]"#,
         #"{"type":"image","mimeType":"image/bmp","data":"aGk="}"#),
        (#"[{"type":"resource","resource":{"uri":"u","blob":"aGk="}}]"#,
         #"{"type":"resource","resource":{"uri":"u","blob":"aGk="}}"#),
        (#"[{"type":"resource_link","uri":"u","name":"n","title":null,"description":"d","size":3,"_meta":{"k":1}}]"#,
         #"{"type":"resource_link","uri":"u","name":"n","title":null,"description":"d","size":3,"_meta":{"k":1}}"#),
        (#"[{"type":"video","type":"text","text":"dup"}]"#, #"{"type":"text","text":"dup"}"#)
    ]

    @Test(arguments: takenAsWritten)
    func aBlockAcpxTakesGoesOnAsWritten(source: String, block: String) {
        #expect(outcome(source) == block)
    }

    // MARK: - Text

    @Test func textIsTrimmedAsJavaScriptTrimsIt() {
        #expect(outcome("\u{FEFF}  fix the failing tests\u{00A0}\n")
            == #"{"type":"text","text":"fix the failing tests"}"#)
        #expect(outcome("   \n\t ").isEmpty)
    }

    /// A prompt may open with a bracket, and JSON that is not an array is text too.
    @Test func whatIsNoStructuredPromptIsText() {
        #expect(outcome("[WIP] rename") == #"{"type":"text","text":"[WIP] rename"}"#)
        #expect(outcome("[1, 2") == #"{"type":"text","text":"[1, 2"}"#)
        #expect(outcome(#"{"type":"text","text":"hi"}"#)
            == #"{"type":"text","text":"{\"type\":\"text\",\"text\":\"hi\"}"}"#)
    }

    /// An empty array is an empty prompt, which the caller reports.
    @Test func anEmptyArrayIsAnEmptyPrompt() {
        #expect(outcome("[]").isEmpty)
    }

    // MARK: - Reading a file

    private func file(_ contents: Data) throws -> (directory: String, name: String) {
        let directory = NSTemporaryDirectory() + "prompt-input-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try contents.write(to: URL(fileURLWithPath: directory + "/prompt.json"))
        return (directory, "prompt.json")
    }

    /// Words given with `--file` follow its blocks as one more text block.
    @Test func wordsFollowAFilesBlocks() throws {
        let (directory, name) = try file(Data(#"[{"type":"text","text":"look"}]"#.utf8))
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let blocks = try PromptInputResolver.resolve(words: ["and", " tell me "], file: name, cwd: directory)
        #expect(blocks.map(\.stringified)
            == [#"{"type":"text","text":"look"}"#, #"{"type":"text","text":"and  tell me"}"#])
    }

    /// Node reads the file as UTF-8, a bad sequence becoming U+FFFD — not as nothing.
    @Test func aFileThatIsNoUTF8IsReadAsNodeReadsIt() throws {
        let (directory, name) = try file(Data([0x68, 0x69, 0x20, 0xC3]))
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let blocks = try PromptInputResolver.resolve(words: [], file: name, cwd: directory)
        #expect(blocks.map(\.stringified) == [#"{"type":"text","text":"hi \#u{FFFD}"}"#])
    }

    /// A file that cannot be read fails in Node's words, which acpx passes on.
    @Test func aFileThatCannotBeReadFailsInNodesWords() throws {
        let directory = NSTemporaryDirectory() + "prompt-input-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory + "/sub", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = URL(fileURLWithPath: directory).standardizedFileURL.path
        let missing = #expect(throws: PromptInputResolver.FileReadError.self) {
            _ = try PromptInputResolver.resolve(words: [], file: "sub/../missing.json", cwd: directory)
        }
        #expect(missing?.message == "ENOENT: no such file or directory, open '\(path)/missing.json'")
        let folder = #expect(throws: PromptInputResolver.FileReadError.self) {
            _ = try PromptInputResolver.resolve(words: [], file: "sub", cwd: directory)
        }
        #expect(folder?.message == "EISDIR: illegal operation on a directory, read")
    }

    /// A block acpx refuses is a usage error.
    @Test func aRefusedBlockIsAUsageError() throws {
        let (directory, name) = try file(Data(#"[{"type":"video"}]"#.utf8))
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let error = #expect(throws: InvalidArgumentError.self) {
            _ = try PromptInputResolver.resolve(words: [], file: name, cwd: directory)
        }
        #expect(error?.message == #"prompt[0] has unsupported content block type "video""#)
    }
}
