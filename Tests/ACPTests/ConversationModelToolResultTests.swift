@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// How a tool call's result is merged across the partial updates an agent streams.
/// A patch carries only what changed, so an absent `status` means "unchanged" — it
/// must not read as "not an error" and wipe a recorded failure (acpx 0.19.0's
/// `is_error: status === undefined ? undefined : …`, issue #23).
struct ConversationModelToolResultTests {
    private func seededRecord() -> SessionRecord {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: "tr-1", acpSessionId: "tr-1", agentCommand: "codex", cwd: "/tmp",
            createdAt: now, lastUsedAt: now)
        ConversationModel.recordPromptSubmission(into: &record, prompt: "run the tests")
        return record
    }

    private func apply(_ update: SessionUpdate, to record: inout SessionRecord) {
        ConversationModel.recordSessionUpdate(
            into: &record, notification: SessionNotification(sessionId: "tr-1", update: update))
    }

    private func result(_ record: SessionRecord, _ id: String) -> SessionToolResult? {
        for message in record.messages.reversed() {
            if case .agent(let agent) = message, let result = agent.toolResults[id] {
                return result
            }
        }
        return nil
    }

    @Test func recordedFailureSurvivesAnOutputOnlyUpdate() {
        var record = seededRecord()
        apply(
            .toolCall(
                ToolCall(
                    toolCallId: "call-1", title: "run tests", status: .failed,
                    rawOutput: .object(["error": .string("exit 1")]))),
            to: &record)
        #expect(result(record, "call-1")?.isError == true)

        // A trailing chunk of output, with no status: the failure must stand.
        apply(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: "call-1",
                    rawOutput: .object(["error": .string("exit 1"), "tail": .string("2 failed")]))),
            to: &record)
        #expect(result(record, "call-1")?.isError == true)
    }

    @Test func anExplicitTerminalStatusStillClearsTheFailure() {
        var record = seededRecord()
        apply(
            .toolCall(ToolCall(toolCallId: "call-2", title: "retryable", status: .failed)),
            to: &record)
        #expect(result(record, "call-2")?.isError == true)

        // Preserved, not frozen: a status that *is* sent still wins.
        apply(
            .toolCallUpdate(ToolCallUpdate(toolCallId: "call-2", status: .completed)),
            to: &record)
        #expect(result(record, "call-2")?.isError == false)
    }

    @Test func aFirstPatchWithoutStatusDefaultsToNotAnError() {
        var record = seededRecord()
        // Title-only counts as a result patch upstream, and with nothing recorded yet
        // it falls back to `is_error: false`, `content: {Text: ""}`.
        apply(
            .toolCallUpdate(ToolCallUpdate(toolCallId: "call-3", title: "fresh call")),
            to: &record)

        let fresh = result(record, "call-3")
        #expect(fresh?.isError == false)
        #expect(fresh?.content == .object(["Text": .string("")]))
    }

    @Test func recordedOutputSurvivesAStatusOnlyUpdate() {
        var record = seededRecord()
        apply(
            .toolCall(
                ToolCall(
                    toolCallId: "call-4", title: "read file", status: .inProgress,
                    rawOutput: .string("the file body"))),
            to: &record)
        #expect(result(record, "call-4")?.content == .object(["Text": .string("the file body")]))

        // The terminal update carries only the status — the output stands.
        apply(
            .toolCallUpdate(ToolCallUpdate(toolCallId: "call-4", status: .completed)),
            to: &record)
        let final = result(record, "call-4")
        #expect(final?.content == .object(["Text": .string("the file body")]))
        #expect(final?.output == .string("the file body"))
        #expect(final?.isError == false)
    }
}
