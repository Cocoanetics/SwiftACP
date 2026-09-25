@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// What a `usage_update` records, as acpx 0.19.1 records it: only what its ACP SDK
/// (`@agentclientprotocol/sdk` 1.5.0, `zUsageUpdate`) lets through (#155). The SDK drops an
/// update whose `used` or `size` is not a number, and strips every key but `used`, `size`,
/// `cost` and `_meta`, so the token counts come from `_meta.usage` alone. It keeps a cost
/// only with a number `amount` and a string `currency`.
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

    /// One update as the agent sends it, and what acpx records of it.
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var update: String
        var inputTokens: Double?
        var cost: SessionUsageCost?
        var testDescription: String { name }
    }

    /// Each checked against acpx 0.19.1, the agent sending the update in a turn.
    static let cases: [Case] = [
        Case(name: "the breakdown under _meta.usage", update:
            #"{"sessionUpdate":"usage_update","used":5,"size":100,"_meta":{"usage":{"inputTokens":7}}}"#,
            inputTokens: 7),
        Case(name: "counts on the update itself", update:
            #"{"sessionUpdate":"usage_update","used":5,"size":100,"inputTokens":3,"output_tokens":4}"#),
        Case(name: "no used or size", update:
            #"{"sessionUpdate":"usage_update","cost":{"amount":1,"currency":"USD"},"#
                + #""_meta":{"usage":{"input_tokens":1}}}"#),
        Case(name: "a size that is a string", update:
            #"{"sessionUpdate":"usage_update","used":5,"size":"100","_meta":{"usage":{"input_tokens":8}}}"#),
        Case(name: "a fractional used", update:
            #"{"sessionUpdate":"usage_update","used":5.5,"size":100,"_meta":{"usage":{"input_tokens":2}}}"#,
            inputTokens: 2),
        Case(name: "an amount that is a string", update:
            #"{"sessionUpdate":"usage_update","used":5,"size":100,"cost":{"amount":"x","currency":"USD"},"#
                + #""_meta":{"usage":{"input_tokens":3}}}"#,
            inputTokens: 3),
        Case(name: "a cost without its currency", update:
            #"{"sessionUpdate":"usage_update","used":5,"size":100,"cost":{"amount":0.5},"#
                + #""_meta":{"usage":{"input_tokens":4}}}"#,
            inputTokens: 4),
        Case(name: "a cost", update:
            #"{"sessionUpdate":"usage_update","used":5,"size":100,"cost":{"amount":0.25,"currency":"USD"}}"#,
            cost: SessionUsageCost(amount: 0.25, currency: "USD")),
        Case(name: "a negative amount", update:
            #"{"sessionUpdate":"usage_update","used":5,"size":100,"cost":{"amount":-1,"currency":"USD"}}"#,
            cost: SessionUsageCost(currency: "USD")),
        Case(name: "a blank currency", update:
            #"{"sessionUpdate":"usage_update","used":5,"size":100,"cost":{"amount":0.5,"currency":"  "}}"#,
            cost: SessionUsageCost(amount: 0.5)),
        Case(name: "a _meta that is not an object", update:
            #"{"sessionUpdate":"usage_update","used":5,"size":100,"_meta":"x","inputTokens":6}"#),
        Case(name: "only the context window", update: #"{"sessionUpdate":"usage_update","used":50,"size":1000}"#)
    ]

    @Test(arguments: cases)
    func anUpdateRecordsWhatAcpxRecordsOfIt(_ given: Case) throws {
        var session = record(id: "usage")
        try apply(given.update, to: &session)

        #expect(session.cumulativeTokenUsage?.inputTokens == given.inputTokens)
        #expect(session.requestTokenUsage?.values.first?.inputTokens == given.inputTokens)
        #expect(session.cumulativeCost?.amount == given.cost?.amount)
        #expect(session.cumulativeCost?.currency == given.cost?.currency)
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

    /// The wiring, not just the parameter: the persister must remember the turn's own
    /// prompt, because a user message can be appended before the response lands — the
    /// prompt given as text, or as the blocks the daemon records (#154).
    @Test(arguments: [false, true])
    func thePersisterAttributesUsageToItsOwnPrompt(asBlocks: Bool) async throws {
        try await withIsolatedStore {
            let now = nowISO()
            let seed = SessionRecord(
                acpxRecordId: "tp-1", acpSessionId: "tp-1", agentCommand: "codex", cwd: "/tmp",
                createdAt: now, lastUsedAt: now)
            try SessionStore.writeRecord(seed)

            let persister = TurnPersister(record: seed, intervalNanos: 20_000_000)
            if asBlocks {
                await persister.recordPrompt([ContentBlock.text("the turn's prompt")])
            } else {
                await persister.recordPrompt("the turn's prompt")
            }
            // The agent echoes the user's message back mid-turn, appending a second one.
            await persister.apply(
                .userMessageChunk(ContentBlock.text("echoed back")))
            await persister.applyResponseUsage(PromptUsage(inputTokens: 10, outputTokens: 5))
            await persister.finish()

            let final = try #require(SessionStore.loadRecord("tp-1"))
            let userIds = final.messages.compactMap { message -> String? in
                if case .user(let user) = message { return user.id }
                return nil
            }
            #expect(userIds.count == 2)
            // Attributed to the first, not to the echo that arrived after it.
            #expect(final.requestTokenUsage?[try #require(userIds.first)]?.inputTokens == 10)
            #expect(final.requestTokenUsage?.count == 1)
        }
    }
}
