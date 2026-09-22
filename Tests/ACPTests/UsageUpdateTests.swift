@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// Where a `usage_update`'s token breakdown is read from. acpx takes `_meta.usage` when
/// the adapter nests it there and otherwise the update record itself, so an adapter that
/// reports the breakdown at the top level is captured too (acpx 0.11.2, issue #28).
struct UsageUpdateTests {
    private func record(id: String) -> SessionRecord {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: id, acpSessionId: id, agentCommand: "claude", cwd: "/tmp",
            createdAt: now, lastUsedAt: now)
        ConversationModel.recordPromptSubmission(into: &record, prompt: "hi")
        return record
    }

    private func apply(_ json: String, to record: inout SessionRecord) throws {
        let update = try JSONDecoder().decode(SessionUpdate.self, from: Data(json.utf8))
        ConversationModel.recordSessionUpdate(
            into: &record, notification: SessionNotification(sessionId: "u", update: update))
    }

    @Test func breakdownReportedOnTheUpdateItselfIsCaptured() throws {
        var session = record(id: "flat")
        try apply(
            #"{"sessionUpdate":"usage_update","used":10,"size":100,"#
                + #""inputTokens":800,"outputTokens":400,"totalTokens":1200}"#,
            to: &session)

        #expect(session.cumulativeTokenUsage?.inputTokens == 800)
        #expect(session.cumulativeTokenUsage?.outputTokens == 400)
        #expect(session.cumulativeTokenUsage?.totalTokens == 1200)
        #expect(session.requestTokenUsage?.values.first?.inputTokens == 800)
    }

    @Test func nestedMetaUsageStillWins() throws {
        var session = record(id: "nested")
        // Both present: `_meta.usage` is the documented location and takes precedence.
        try apply(
            #"{"sessionUpdate":"usage_update","inputTokens":1,"#
                + #""_meta":{"usage":{"inputTokens":800,"outputTokens":400}}}"#,
            to: &session)

        #expect(session.cumulativeTokenUsage?.inputTokens == 800)
        #expect(session.cumulativeTokenUsage?.outputTokens == 400)
    }

    @Test func aBareContextUpdateStillRecordsNoBreakdown() throws {
        var session = record(id: "bare")
        // Codex-shaped: context window only, no token fields anywhere — unchanged.
        try apply(#"{"sessionUpdate":"usage_update","used":50,"size":1000}"#, to: &session)

        #expect(session.cumulativeTokenUsage == nil)
        #expect(session.cumulativeCost == nil)
    }
}
