import Foundation
import SwiftACP
import Testing

/// Antigravity encodes interaction questions as permission requests whose answers are
/// marked `allow_once`, so any policy that approves would be answering a question meant
/// for a person. The client cancels them ahead of the handler instead — acpx 0.17.1's
/// breaking rule, which takes precedence over every permission mode (issue #30).
struct AntigravityQuestionTests {
    static let antigravity = AntigravityCompat.agentName

    static func request(toolCallId: String) -> RequestPermissionRequest {
        RequestPermissionRequest(
            sessionId: "s",
            toolCall: ToolCallUpdate(toolCallId: toolCallId, title: "Which file?", kind: .other),
            options: [
                PermissionOption(optionId: "answer-a", name: "config.json", kind: .allowOnce),
                PermissionOption(optionId: "answer-b", name: "main.swift", kind: .allowOnce)
            ])
    }

    // MARK: - AntigravityCompat (pure)

    @Test func recognisesOnlyAntigravitysInteractionIds() {
        #expect(AntigravityCompat.isInteractionQuestion(
            Self.request(toolCallId: "interaction_1"), agentName: Self.antigravity))
        // An ordinary tool permission from the same adapter is a real decision.
        #expect(!AntigravityCompat.isInteractionQuestion(
            Self.request(toolCallId: "tool-7"), agentName: Self.antigravity))
        // The prefix is only meaningful for Antigravity; other adapters' ids are opaque.
        #expect(!AntigravityCompat.isInteractionQuestion(
            Self.request(toolCallId: "interaction_1"), agentName: CodexCompat.agentName))
        #expect(!AntigravityCompat.isInteractionQuestion(
            Self.request(toolCallId: "interaction_1"), agentName: nil))
    }

    // MARK: - Loopback turns through the real client

    /// The crux: the most permissive mode there is still cannot answer a question.
    @Test(arguments: [PermissionRefusalTests.Mode.approveAll, .approveReads, .denyAll])
    func noPermissionModeAnswersAQuestion(mode: PermissionRefusalTests.Mode) async throws {
        let probe = try await PermissionRefusalTests.runProbe(
            PermissionRefusalTests.ProbeAgent(
                agentName: Self.antigravity, refusalIds: [], toolCallId: "interaction_42"),
            policy: mode.policy)

        #expect(probe.answer == "cancelled")
        #expect(probe.echoedNotice == AntigravityCompat.questionNotice)
        // Explained once on the event subscription, before the agent reacts.
        #expect(probe.operations.count == 1)
        #expect(probe.operations.first?.summary == AntigravityCompat.questionNotice)
    }

    /// A host resolver is not an escape hatch either: it is never consulted.
    @Test func aHostResolverIsNotConsultedForAQuestion() async throws {
        let probe = try await PermissionRefusalTests.runProbe(
            PermissionRefusalTests.ProbeAgent(
                agentName: Self.antigravity, refusalIds: [], toolCallId: "interaction_7"),
            policy: .custom { _ in .selected("answer-a") })

        #expect(probe.answer == "cancelled")
    }

    /// Ordinary permissions from Antigravity are ordinary permissions.
    @Test func anOrdinaryAntigravityPermissionStillFollowsThePolicy() async throws {
        let probe = try await PermissionRefusalTests.runProbe(
            PermissionRefusalTests.ProbeAgent(
                agentName: Self.antigravity, refusalIds: ["reject"], toolCallId: "tool-7"),
            policy: PermissionRefusalTests.Mode.approveAll.policy)

        #expect(probe.answer == "selected:allow")
        #expect(probe.echoedNotice == nil)
        #expect(probe.operations.isEmpty)
    }

    /// Another adapter's `interaction_`-prefixed id means nothing to us.
    @Test func otherAdaptersKeepTheirInteractionPrefixedIds() async throws {
        let probe = try await PermissionRefusalTests.runProbe(
            PermissionRefusalTests.ProbeAgent(
                agentName: "some-other-acp", refusalIds: [], toolCallId: "interaction_9"),
            policy: PermissionRefusalTests.Mode.approveAll.policy)

        #expect(probe.answer == "selected:allow")
    }
}
