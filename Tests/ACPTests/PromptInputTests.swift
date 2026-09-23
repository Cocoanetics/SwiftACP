@testable import acpx
import Foundation
import SwiftACP
import Testing

/// The CLI's structured prompt input — npm acpx's `parsePromptSource`, which reads a
/// `--file` or piped source starting with `[` as a JSON array of ACP content blocks.
struct PromptInputTests {
    private func parse(_ source: String) throws -> [PromptBlock] {
        try PromptInputResolver.parse(source)
    }

    // MARK: - Plain text

    @Test func plainTextBecomesOneTextBlock() throws {
        let blocks = try parse("  fix the failing tests\n")
        #expect(blocks.count == 1)
        #expect(blocks.first?.type == "text")
        #expect(blocks.first?.text == "fix the failing tests")
    }

    @Test func blankSourceYieldsNothing() throws {
        #expect(try parse("").isEmpty)
        #expect(try parse("   \n\t ").isEmpty)
    }

    // MARK: - Structured

    @Test func aJSONArrayOfBlocksIsParsedStructurally() throws {
        let blocks = try parse("""
            [{"type":"text","text":"what is this?"},
             {"type":"image","mimeType":"image/png","data":"\(PromptBlocksTests.pngBase64)"}]
            """)
        #expect(blocks.count == 2)
        #expect(blocks.first?.text == "what is this?")
        #expect(blocks.last?.type == "image")
        #expect(blocks.last?.mimeType == "image/png")
    }

    /// The reason structured input matters beyond images: handing over a file.
    @Test func resourceLinksSurviveParsing() throws {
        let blocks = try parse("""
            [{"type":"resource_link","uri":"file:///tmp/spec.pdf","name":"spec.pdf"}]
            """)
        #expect(blocks.count == 1)
        #expect(blocks.first?.uri == "file:///tmp/spec.pdf")
        #expect(blocks.first?.name == "spec.pdf")
    }

    /// An empty array parses — the caller turns it into "prompt is empty", not into a
    /// text block reading "[]".
    @Test func anEmptyArrayIsAnEmptyPrompt() throws {
        #expect(try parse("[]").isEmpty)
    }

    // MARK: - Falling back to text

    /// A prompt may legitimately open with a bracket, so a source that starts with
    /// `[` but is not JSON is text, not an error — matching upstream.
    @Test func bracketedTextThatIsNotJSONStaysText() throws {
        for source in ["[WIP] rename the module", "[1, 2", "[not json at all]"] {
            let blocks = try parse(source)
            #expect(blocks.count == 1, "\(source)")
            #expect(blocks.first?.type == "text", "\(source)")
            #expect(blocks.first?.text == source, "\(source)")
        }
    }

    /// JSON that is not an array is text too — only an array means structured.
    @Test func nonArrayJSONStaysText() throws {
        let blocks = try parse("{\"type\":\"text\",\"text\":\"hi\"}")
        #expect(blocks.count == 1)
        #expect(blocks.first?.type == "text")
        #expect(blocks.first?.text == "{\"type\":\"text\",\"text\":\"hi\"}")
    }

    // MARK: - Structured, but wrong

    /// Valid JSON array, invalid contents: an error naming the index, rather than
    /// silently sending the JSON as prose.
    @Test func aJSONArrayOfNonBlocksIsAnError() {
        #expect(throws: InvalidArgumentError.self) { _ = try parse("[1, 2, 3]") }
        #expect(throws: InvalidArgumentError.self) { _ = try parse("[{\"text\":\"no type field\"}]") }
    }

    @Test func invalidBlocksReportTheOffendingIndex() {
        let error = #expect(throws: InvalidArgumentError.self) {
            _ = try parse("""
                [{"type":"text","text":"ok"},{"type":"image","mimeType":"image/bmp","data":"aGk="}]
                """)
        }
        #expect(error?.message.contains("prompt[1]") == true)
    }

    /// The guidance a caller needs when they reach for a PDF, surfaced by the CLI.
    @Test func aBinaryResourceIsRefusedWithGuidance() {
        let error = #expect(throws: InvalidArgumentError.self) {
            _ = try parse("""
                [{"type":"resource","uri":"file:///tmp/spec.pdf","mimeType":"application/pdf"}]
                """)
        }
        #expect(error?.message.contains("resource_link") == true)
    }
}
