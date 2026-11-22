import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Antigravity encodes interaction questions as permission requests whose answers are
/// marked `allow_once`, so any policy that approves would be answering a question meant
/// for a person. The client cancels them ahead of the handler instead — acpx 0.17.1's
/// breaking rule, which takes precedence over every permission mode (issue #30, #346).
struct AntigravityQuestionTests {
    static let antigravity = AntigravityCompat.agentName
    static let questionArgs: JSONValue = .object([
        "question": .string("Which file?"),
        "choices": .array([.string("config.json"), .string("main.swift")])
    ])
    static let mcpArgs: JSONValue = .object([
        "number": .integer(277),
        "repo": .string("Cocoanetics/SwiftPorts")
    ])

    static func request(
        toolCallId: String, name: String? = nil, args: JSONValue? = nil
    ) -> RequestPermissionRequest {
        RequestPermissionRequest(
            sessionId: "s",
            toolCall: ToolCallUpdate(
                toolCallId: toolCallId, title: "Which file?", kind: .other,
                name: name, args: args),
            options: [
                PermissionOption(optionId: "answer-a", name: "config.json", kind: .allowOnce),
                PermissionOption(optionId: "answer-b", name: "main.swift", kind: .allowOnce)
            ])
    }

    // MARK: - AntigravityCompat (pure)

    @Test func recognisesOnlyAntigravitysInteractionIds() {
        #expect(AntigravityCompat.isInteractionQuestion(
            Self.request(toolCallId: "interaction_1"), agentName: Self.antigravity))
        #expect(AntigravityCompat.isInteractionQuestion(
            Self.request(toolCallId: "interaction_1", name: "ask_user_question", args: Self.questionArgs),
            agentName: Self.antigravity))
        // An ordinary tool permission from the same adapter is a real decision, even with name/args.
        #expect(!AntigravityCompat.isInteractionQuestion(
            Self.request(toolCallId: "tool-7", name: "mcp_missioncontrol_view_issue", args: Self.mcpArgs),
            agentName: Self.antigravity))
        // The prefix is only meaningful for Antigravity; other adapters' ids are opaque.
        #expect(!AntigravityCompat.isInteractionQuestion(
            Self.request(toolCallId: "interaction_1", name: "ask_user_question", args: Self.questionArgs),
            agentName: CodexCompat.agentName))
        #expect(!AntigravityCompat.isInteractionQuestion(
            Self.request(toolCallId: "interaction_1", name: "ask_user_question", args: Self.questionArgs),
            agentName: nil))
    }

    // MARK: - Loopback turns through the real client

    /// The crux: the most permissive mode there is still cannot answer a question —
    /// including when `toolCall` carries adapter `name` and `args`. The cancellation notice
    /// is announced on the event subscription before the agent reacts to the answer.
    @Test(arguments: [PermissionRefusalTests.Mode.approveAll, .approveReads, .denyAll])
    func noPermissionModeAnswersAQuestion(mode: PermissionRefusalTests.Mode) async throws {
        let probe = try await PermissionRefusalTests.runProbe(
            PermissionRefusalTests.ProbeAgent(
                agentName: Self.antigravity, refusalIds: [], toolCallId: "interaction_42",
                toolName: "ask_user_question", toolArgs: Self.questionArgs),
            policy: mode.policy)

        #expect(probe.answer == "cancelled")
        #expect(probe.echoedNotice == AntigravityCompat.questionNotice)
        // Explained once on the event subscription, strictly ahead of the agent's reaction and answer.
        #expect(probe.operations.count == 1)
        #expect(probe.operations.first?.summary == AntigravityCompat.questionNotice)
        #expect(probe.eventOrder.first == "operation")
        #expect(probe.eventOrder.last == "answered")
    }

    /// A host resolver is not an escape hatch either: it is never consulted, even when
    /// the interaction request carries `name` and `args`.
    @Test func aHostResolverIsNotConsultedForAQuestion() async throws {
        actor Calls {
            var count = 0
            func bump() { count += 1 }
        }
        let calls = Calls()
        let probe = try await PermissionRefusalTests.runProbe(
            PermissionRefusalTests.ProbeAgent(
                agentName: Self.antigravity, refusalIds: [], toolCallId: "interaction_7",
                toolName: "ask_user_question", toolArgs: Self.questionArgs),
            policy: .custom { _ in
                await calls.bump()
                return .selected("answer-a")
            })

        #expect(probe.answer == "cancelled")
        #expect(probe.echoedNotice == AntigravityCompat.questionNotice)
        #expect(probe.operations.count == 1)
        #expect(probe.operations.first?.summary == AntigravityCompat.questionNotice)
        #expect(probe.eventOrder.first == "operation")
        #expect(probe.eventOrder.last == "answered")
        #expect(await calls.count == 0)
    }

    /// Ordinary permissions from Antigravity — including those with `name` and `args` —
    /// still follow the permission policy and reach custom handlers with exact fields.
    @Test func anOrdinaryAntigravityPermissionStillFollowsThePolicy() async throws {
        let approved = try await PermissionRefusalTests.runProbe(
            PermissionRefusalTests.ProbeAgent(
                agentName: Self.antigravity, refusalIds: ["reject"], toolKind: .other,
                toolCallId: "tool-7", toolName: "mcp_missioncontrol_view_issue", toolArgs: Self.mcpArgs),
            policy: PermissionRefusalTests.Mode.approveAll.policy)

        #expect(approved.answer == "selected:allow")
        #expect(approved.echoedNotice == nil)
        #expect(approved.operations.isEmpty)

        actor Seen {
            var request: RequestPermissionRequest?
            func record(_ request: RequestPermissionRequest) { self.request = request }
        }
        let seen = Seen()
        let custom = try await PermissionRefusalTests.runProbe(
            PermissionRefusalTests.ProbeAgent(
                agentName: Self.antigravity, refusalIds: ["reject"], toolKind: .other,
                toolCallId: "tool-7", toolName: "mcp_missioncontrol_view_issue", toolArgs: Self.mcpArgs),
            policy: .custom { request in
                await seen.record(request)
                return .selected("reject")
            })

        #expect(custom.answer == "selected:reject")
        #expect(custom.echoedNotice == nil)
        #expect(custom.operations.isEmpty)
        let received = try #require(await seen.request)
        #expect(received.toolCall.name == "mcp_missioncontrol_view_issue")
        #expect(received.toolCall.args == Self.mcpArgs)
    }

    /// Another adapter's `interaction_`-prefixed id — even with `name` and `args` —
    /// means nothing to AntigravityCompat and reaches policies and custom handlers intact.
    @Test func otherAdaptersKeepTheirInteractionPrefixedIds() async throws {
        let approved = try await PermissionRefusalTests.runProbe(
            PermissionRefusalTests.ProbeAgent(
                agentName: "some-other-acp", refusalIds: [], toolCallId: "interaction_9",
                toolName: "ask_user_question", toolArgs: Self.questionArgs),
            policy: PermissionRefusalTests.Mode.approveAll.policy)

        #expect(approved.answer == "selected:allow")
        #expect(approved.echoedNotice == nil)
        #expect(approved.operations.isEmpty)

        actor Seen {
            var request: RequestPermissionRequest?
            func record(_ request: RequestPermissionRequest) { self.request = request }
        }
        let seen = Seen()
        let custom = try await PermissionRefusalTests.runProbe(
            PermissionRefusalTests.ProbeAgent(
                agentName: "some-other-acp", refusalIds: [], toolCallId: "interaction_9",
                toolName: "ask_user_question", toolArgs: Self.questionArgs),
            policy: .custom { request in
                await seen.record(request)
                return .selected("allow")
            })

        #expect(custom.answer == "selected:allow")
        #expect(custom.echoedNotice == nil)
        #expect(custom.operations.isEmpty)
        let received = try #require(await seen.request)
        #expect(received.toolCall.name == "ask_user_question")
        #expect(received.toolCall.args == Self.questionArgs)
    }
}
