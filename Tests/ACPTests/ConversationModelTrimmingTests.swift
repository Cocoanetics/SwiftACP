@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// How long a text a record keeps (#118): acpx's `trimRuntimeText` counts and cuts in
/// UTF-16 code units — JavaScript's `length` and `slice` — not in characters.
struct ConversationModelTrimmingTests {
    private static func agentText(after chunks: [String]) -> String? {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: "t-1", acpSessionId: "t-1", agentCommand: "agent", cwd: "/tmp", createdAt: now,
            lastUsedAt: now)
        ConversationModel.recordPromptSubmission(into: &record, prompt: "go")
        for chunk in chunks {
            ConversationModel.recordSessionUpdate(
                into: &record,
                notification: SessionNotification(sessionId: "t-1", update: .agentMessageChunk(.text(chunk))))
        }
        guard case .agent(let agent)? = record.messages.last, case .text(let text)? = agent.content.first else {
            return nil
        }
        return text
    }

    /// Past 8,000 UTF-16 units an agent's text keeps its first 7,997 and `...`. 5,000
    /// emoji are 10,000 units: a cut there would split the 3,999th's surrogate pair, so it
    /// keeps one unit less and leaves the pair out, as acpx 0.19.3 cuts it (7,999 units,
    /// what its `trimRuntimeText` makes of the same text).
    @Test func textPastTheLimitIsCutInUTF16Units() throws {
        let text = try #require(Self.agentText(after: [String(repeating: "😀", count: 5_000)]))
        #expect(text == String(repeating: "😀", count: 3_998) + "...")
        #expect(text.utf16.count == 7_999)
    }

    /// Only a cut after a pair's first half steps back: `a😀` repeated puts that half at
    /// the cut in one place of three, and a letter or a whole pair is kept as it is.
    @Test func onlyACutThroughAPairStepsBack() throws {
        let text = try #require(Self.agentText(after: [String(repeating: "a😀", count: 5_000)]))
        #expect(text == String(repeating: "a😀", count: 2_665) + "a...")
        #expect(text.utf16.count == 7_999)
        let pairs = try #require(Self.agentText(after: ["a" + String(repeating: "😀", count: 5_000)]))
        #expect(pairs == "a" + String(repeating: "😀", count: 3_998) + "...")
        #expect(pairs.utf16.count == 8_000)
    }

    /// A character of two units counts as two: 5,000 accented letters, written as a letter
    /// and a combining accent, are 10,000 units, and the cut can leave a letter without
    /// its accent.
    @Test func combiningSequencesCountTheirUnits() throws {
        let text = try #require(Self.agentText(after: [String(repeating: "e\u{0301}", count: 5_000)]))
        #expect(text == String(repeating: "e\u{0301}", count: 3_998) + "e...")
    }

    /// A text of exactly the limit is kept whole; one unit more and it is cut. Chunks
    /// count together, as they make one text.
    @Test func theLimitIsInclusive() throws {
        let limit = String(repeating: "a", count: 8_000)
        #expect(Self.agentText(after: [limit]) == limit)
        #expect(Self.agentText(after: [String(repeating: "a", count: 4_000), String(repeating: "a", count: 4_001)])
            == String(repeating: "a", count: 7_997) + "...")
    }
}
