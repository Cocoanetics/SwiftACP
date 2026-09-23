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

    // MARK: Usage on the prompt response

    private func usage(_ json: String) throws -> PromptUsage {
        try JSONDecoder().decode(PromptUsage.self, from: Data(json.utf8))
    }

    @Test func responseUsageAcceptsAcpxsSpellings() throws {
        let snake = try usage(
            #"{"input_tokens":800,"output_tokens":400,"total_tokens":1200,"#
                + #""cache_read_input_tokens":7,"cache_creation_input_tokens":9,"#
                + #""thought_tokens":3}"#)
        #expect(snake.inputTokens == 800)
        #expect(snake.outputTokens == 400)
        #expect(snake.totalTokens == 1200)
        #expect(snake.cachedReadTokens == 7)
        #expect(snake.cachedWriteTokens == 9)
        #expect(snake.thoughtTokens == 3)

        // The `cached*` aliases are the third spelling acpx accepts for the cache fields.
        let aliased = try usage(#"{"cachedReadTokens":5,"cachedWriteTokens":6}"#)
        #expect(aliased.cachedReadTokens == 5)
        #expect(aliased.cachedWriteTokens == 6)
    }

    @Test func anUnusableNumberFallsThroughToTheNextSpelling() throws {
        // acpx's `numberField` skips a present-but-negative value and keeps looking.
        let recovered = try usage(#"{"input_tokens":-1,"inputTokens":42}"#)
        #expect(recovered.inputTokens == 42)

        let none = try usage(#"{"input_tokens":-1}"#)
        #expect(none.inputTokens == nil)
    }

    @Test func responseUsageIsAttributedToTheTurnsMessage() throws {
        var session = record(id: "resp")
        // A second user message lands before the first turn's usage arrives.
        ConversationModel.recordPromptSubmission(into: &session, prompt: "second")
        let first = try #require(session.messages.compactMap { message -> String? in
            if case .user(let user) = message { return user.id }
            return nil
        }.first)

        let recorded = ConversationModel.recordResponseUsage(
            into: &session, PromptUsage(inputTokens: 10, outputTokens: 5),
            promptMessageId: first, timestamp: "2031-01-01T00:00:00.000Z")

        #expect(recorded)
        #expect(session.requestTokenUsage?[first]?.inputTokens == 10)
        // acpx stamps the conversation when usage lands.
        #expect(session.updatedAt == "2031-01-01T00:00:00.000Z")
    }

    @Test func anEmptyBreakdownRecordsNothing() {
        var session = record(id: "empty")
        let before = session.updatedAt
        #expect(!ConversationModel.recordResponseUsage(into: &session, PromptUsage()))
        #expect(session.cumulativeTokenUsage == nil)
        #expect(session.updatedAt == before)
    }
}
