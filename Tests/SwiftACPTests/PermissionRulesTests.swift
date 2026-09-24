@testable import SwiftACP
import Foundation
import JSONFoundation
import Testing

/// acpx's per-tool permission policy (`--permission-policy`, #97): rules that approve,
/// deny or escalate a permission request ahead of the mode. Outcomes and the
/// escalation's shape are acpx 0.19.1's.
@Suite(.timeLimit(.minutes(1)))
struct PermissionRulesTests {
    private static let options = [
        PermissionOption(optionId: "allow", name: "Allow", kind: .allowOnce),
        PermissionOption(optionId: "reject", name: "Reject", kind: .rejectOnce)
    ]

    private static func request(
        title: String? = "Edit notes.txt", kind: ToolKind? = .edit, rawInput: JSONValue? = nil
    ) -> RequestPermissionRequest {
        var toolCall = ToolCallUpdate(toolCallId: "t1", title: title, kind: kind)
        toolCall.rawInput = rawInput
        return RequestPermissionRequest(sessionId: "s", toolCall: toolCall, options: options)
    }

    private static func selected(_ response: RequestPermissionResponse) -> String? {
        if case .selected(let optionId) = response.outcome { return optionId }
        return nil
    }

    // MARK: Order

    /// A custom resolver answers before any rule: it is acpx's host permission handler,
    /// which acpx asks before resolving under its mode and policy.
    @Test func aCustomResolverAnswersBeforeTheRules() async throws {
        let approval = ToolPermissionApproval(
            policy: .custom { _ in .selected("allow") }, rules: PermissionRules(autoDeny: ["*"]), terminal: .none)
        #expect(Self.selected(try await approval.resolve(Self.request())) == "allow")
        // Under a mode the same rule decides.
        let underMode = ToolPermissionApproval(
            policy: .approveAll, rules: PermissionRules(autoDeny: ["*"]), terminal: .none)
        #expect(Self.selected(try await underMode.resolve(Self.request())) == "reject")
    }

    // MARK: Matching

    /// A rule matches the kind (inferred or given), the title, its first word or the raw
    /// input's tool name, case-insensitively; `*` matches anything.
    @Test func aRuleMatchesKindTitleHeadOrToolName() {
        let matches = { (rule: String, request: RequestPermissionRequest) in
            PermissionRules(autoApprove: [rule]).match(request)?.action == .approve
        }
        #expect(matches("EDIT", Self.request()))
        #expect(matches("edit notes.txt", Self.request()))
        #expect(matches("Edit", Self.request(kind: nil)))
        #expect(matches("run", Self.request(title: "Run: npm test", kind: nil)))
        #expect(matches("execute", Self.request(title: "Run: npm test", kind: nil)))
        let shell = Self.request(title: "Run tests", kind: .execute, rawInput: .object(["tool": .string(" shell ")]))
        #expect(matches("shell", shell))
        #expect(matches("*", Self.request(title: nil, kind: nil)))
        #expect(!matches("read", Self.request()))
        #expect(!matches("notes", Self.request()))
    }

    /// `autoDeny` beats `autoApprove`, which beats `escalate`; `defaultAction` is last,
    /// and names no rule.
    @Test func theRulesGoInAcpxsOrder() {
        let all = PermissionRules(autoApprove: ["edit"], autoDeny: ["*"], escalate: ["edit"], defaultAction: .approve)
        #expect(all.match(Self.request())?.action == .deny)
        #expect(all.match(Self.request())?.rule == "*")
        let approveOverEscalate = PermissionRules(autoApprove: ["edit"], escalate: ["edit"])
        #expect(approveOverEscalate.match(Self.request())?.action == .approve)
        let fallback = PermissionRules(escalate: ["read"], defaultAction: .deny)
        #expect(fallback.match(Self.request())?.action == .deny)
        #expect(fallback.match(Self.request())?.rule == nil)
        #expect(PermissionRules(autoApprove: ["read"]).match(Self.request()) == nil)
    }

    // MARK: Answering

    private static func approval(
        _ rules: PermissionRules, _ policy: PermissionPolicy = .approveReads, terminal: TerminalPermissionPrompt = .none
    ) -> ToolPermissionApproval {
        ToolPermissionApproval(policy: policy, nonInteractive: .fail, rules: rules, terminal: terminal)
    }

    @Test func approveAndDenyComeBeforeTheMode() async throws {
        #expect(Self.selected(try await Self.approval(.init(autoApprove: ["edit"]), .denyAll).resolve(Self.request()))
            == "allow")
        #expect(Self.selected(try await Self.approval(.init(autoDeny: ["edit"]), .approveAll).resolve(Self.request()))
            == "reject")
    }

    /// With nobody to ask, an escalated request is refused, the escalation attached —
    /// not failed, although the mode's own question would have been.
    @Test func anEscalationWithNobodyToAskIsRefusedWithItsDetails() async throws {
        let response = try await Self.approval(.init(escalate: ["edit"]), .approveAll)
            .resolve(Self.request(rawInput: .object(["path": .string("notes.txt")])))
        #expect(Self.selected(response) == "reject")
        let escalation = try #require(response.permissionEscalation)
        #expect(escalation.type == "permission_escalation")
        #expect(escalation.sessionId == "s")
        #expect(escalation.toolCallId == "t1")
        #expect(escalation.toolName == "Edit")
        #expect(escalation.toolTitle == "Edit notes.txt")
        #expect(escalation.toolInput == .object(["path": .string("notes.txt")]))
        #expect(escalation.toolKind == "edit")
        #expect(escalation.action == "escalate")
        #expect(escalation.matchedRule == "edit")
        #expect(escalation.message == "Permission escalation required for Edit notes.txt")
        #expect(escalation.timestamp.hasSuffix("Z"))
    }

    /// With a terminal, an escalated request is asked about, as the mode's question.
    @Test func anEscalationIsAskedOnATerminal() async throws {
        let terminal = TerminalPermissionPromptTests.Terminal()
        terminal.type("y\n")
        let response = try await Self.approval(.init(escalate: ["edit"]), .denyAll, terminal: terminal.prompt)
            .resolve(Self.request())
        #expect(Self.selected(response) == "allow")
        #expect(response.permissionEscalation == nil)
    }

    // MARK: Through the connection

    /// The escalation reaches the connection's subscribers as a permission notice
    /// carrying it, and the refusal counts as a denial.
    @Test func anEscalationIsAnnouncedAndCounted() async throws {
        let gate = WriteGateTests()
        let run = try await gate.run(
            ToolPermissionApprovalTests.PermissionProbeAgent(), cwd: try gate.workspace(),
            handlers: .standard(permission: .approveAll, terminal: .none, rules: .init(escalate: ["edit"])))
        #expect(run.reply == "selected:reject")
        #expect(run.stats.denied == 1)
        #expect(run.operations.map(\.escalation?.message)
            == ["Permission escalation required for Edit notes.txt"])
    }
}
