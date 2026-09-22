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

    @Test func aDeclaredReadKindWinsOverAnyTitle() {
        #expect(ToolText.isReadLike(title: "Spreadsheet update", kind: ToolKind("read")))
        #expect(!ToolText.isReadLike(title: "Spreadsheet update", kind: ToolKind("edit")))
    }
}
