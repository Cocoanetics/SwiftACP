@testable import acpx
import Foundation
import SwiftACP
import Testing

/// Which tool calls count as reads for `--suppress-reads`. The action has to be the
/// title's leading word: a read-like *substring* inside an edit or command title must
/// not hide that tool's output (acpx 0.18.0's `inferToolKindFromTitle`, issue #28).
struct ReadSuppressionTests {
    @Test(arguments: [
        ("Read file.txt", true),
        ("read: src/main.swift", true),
        ("cat config.json", true),
        ("open README", true),
        ("view diff", true),
        // The regressions upstream fixed: "read" and "view" as substrings.
        ("Spreadsheet update", false),
        ("overwrite readme.md", false),
        ("preview changes", false),
        ("git open-pr", false),
        ("already opened", false),
        // A leading separator leaves no action word at all.
        (":read", false),
        ("", false)
    ])
    func classifiesByLeadingActionWord(title: String, expected: Bool) {
        #expect(ToolText.isReadLike(title: title, kind: nil) == expected)
    }

    /// acpx trims with JavaScript's `trim()` and splits on its `\s`, which are not Swift's
    /// whitespace (#112): a line break before the title is trimmed away, a no-break space
    /// or U+FEFF ends the word, and U+0085 does not.
    @Test(arguments: [
        ("\nRead notes.txt", true),
        ("\u{FEFF}view diff", true),
        ("read\u{00A0}notes.txt", true),
        ("read\u{FEFF}notes.txt", true),
        ("read\u{85}notes.txt", false)
    ])
    func titlesAreTrimmedAndSplitAsJavaScriptDoes(title: String, expected: Bool) {
        #expect(ToolText.isReadLike(title: title, kind: nil) == expected)
    }

    @Test func aKindIsTrimmedAsJavaScriptTrimsIt() {
        #expect(ToolText.isReadLike(title: nil, kindName: "\n READ \u{FEFF}"))
    }

    @Test func aDeclaredReadKindWinsOverAnyTitle() {
        #expect(ToolText.isReadLike(title: "Spreadsheet update", kind: ToolKind("read")))
        #expect(!ToolText.isReadLike(title: "Spreadsheet update", kind: ToolKind("edit")))
    }
}

/// A tool update's members sent as JSON `null` clear what was set before, as acpx's
/// `mergeToolPayloadState` has it (#112): a call first reported as a read and then
/// updated with `"kind": null` and a write's title is no read any more, and shows its
/// output under `--suppress-reads`.
struct ToolUpdateMergeTests {
    private static func update(_ json: String) throws -> SessionUpdate {
        try JSONDecoder().decode(SessionUpdate.self, from: Data(json.utf8))
    }

    @Test func aKindSentAsNullIsCleared() throws {
        let (out, _) = OutputRendererTests.capture(.text, suppressReads: true) { renderer in
            try? renderer.render(Self.update("""
                {"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read notes.txt","kind":"read",\
                "status":"in_progress"}
                """))
            try? renderer.render(Self.update("""
                {"sessionUpdate":"tool_call_update","toolCallId":"t1","title":"Write out.txt","kind":null,\
                "status":"completed","content":[{"type":"content","content":{"type":"text","text":"written"}}]}
                """))
        }
        #expect(!out.contains("[read output suppressed]"))
        #expect(out.contains("written"))
        #expect(!out.contains("kind: read"))
    }
}

/// A member a tool update came with as `null` goes back as `null` — unless it has been
/// given a value since, which wins (#115 review).
struct ToolUpdateNullMemberTests {
    private func encoded(_ update: ToolCallUpdate) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
    }

    @Test func aNullMemberGoesBackAsNull() throws {
        let update = try JSONDecoder().decode(
            ToolCallUpdate.self, from: Data(#"{"toolCallId":"t","kind":null,"status":"completed"}"#.utf8))
        #expect(update.nullMembers == ["kind"])
        let json = try encoded(update)
        #expect(json["kind"] is NSNull)
        #expect(json["status"] as? String == "completed")
    }

    @Test func aValueGivenSinceWinsOverTheNull() throws {
        var update = try JSONDecoder().decode(ToolCallUpdate.self, from: Data(#"{"toolCallId":"t","kind":null}"#.utf8))
        update.kind = ToolKind("read")
        #expect(try encoded(update)["kind"] as? String == "read")
    }
}
