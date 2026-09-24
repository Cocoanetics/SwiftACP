@testable import SwiftACP
import Foundation
import JSONFoundation
import Testing

/// How a `session/request_permission` is answered under a permission mode — acpx's
/// `resolvePermissionRequest` (#93). Under `--approve-reads`, a tool that is not a
/// read or search is asked about on the terminal, or, with none, follows
/// `--non-interactive-permissions`: `deny` refuses it, `fail` answers `cancelled` and
/// fails the turn. Outcomes and the question's wording are acpx 0.19.1's.
@Suite(.timeLimit(.minutes(1)))
struct ToolPermissionApprovalTests {
    private static let options = [
        PermissionOption(optionId: "allow", name: "Allow", kind: .allowOnce),
        PermissionOption(optionId: "reject", name: "Reject", kind: .rejectOnce)
    ]

    private static func request(
        title: String? = "Edit notes.txt", kind: ToolKind? = .edit, options: [PermissionOption] = options
    ) -> RequestPermissionRequest {
        RequestPermissionRequest(
            sessionId: "s", toolCall: ToolCallUpdate(toolCallId: "t1", title: title, kind: kind), options: options)
    }

    private static func headless(_ policy: PermissionPolicy, _ nonInteractive: NonInteractivePermissionPolicy = .deny)
        -> ToolPermissionApproval {
        ToolPermissionApproval(policy: policy, nonInteractive: nonInteractive, terminal: .none)
    }

    private static func selected(_ response: RequestPermissionResponse) -> String? {
        if case .selected(let optionId) = response.outcome { return optionId }
        return nil
    }

    // MARK: The kind

    /// acpx's `inferToolKind`: the request's kind, else its title's first word.
    @Test func theKindIsTheRequestsElseItsTitlesFirstWord() {
        let inferred = { (title: String?, kind: ToolKind?) in
            ToolPermissionApproval.inferredKind(of: Self.request(title: title, kind: kind))
        }
        #expect(inferred("Read notes.txt", .edit) == .edit)
        #expect(inferred("Read notes.txt", nil) == .read)
        #expect(inferred("  cat: notes.txt", nil) == .read)
        #expect(inferred("GREP foo", nil) == .search)
        #expect(inferred("find . -name x", nil) == .search)
        #expect(inferred("patch file", nil) == .edit)
        #expect(inferred("remove it", nil) == .delete)
        #expect(inferred("rename a b", nil) == .move)
        #expect(inferred("bash -c x", nil) == .execute)
        #expect(inferred("http get", nil) == .fetch)
        #expect(inferred("think", nil) == .think)
        // A read-like word later in the title does not make it a read.
        #expect(inferred("Update README, then read it", nil) == .other)
        #expect(inferred("", nil) == nil)
        #expect(inferred(nil, nil) == nil)
        #expect(inferred(":x", nil) == nil)
    }

    // MARK: Without a terminal

    @Test func readsAndSearchesAreApproved() async throws {
        let approval = Self.headless(.approveReads)
        #expect(Self.selected(try await approval.resolve(Self.request(title: "cat x", kind: nil))) == "allow")
        #expect(Self.selected(try await approval.resolve(Self.request(kind: .search))) == "allow")
    }

    /// A read that offers nothing to allow is no exception: it goes the way of any
    /// other tool.
    @Test func aReadWithoutAnAllowOptionIsNotApproved() async throws {
        let rejectOnly = [PermissionOption(optionId: "reject", name: "Reject", kind: .rejectOnce)]
        let response = try await Self.headless(.approveReads).resolve(Self.request(kind: .read, options: rejectOnly))
        #expect(Self.selected(response) == "reject")
    }

    @Test func anythingElseIsRefusedUnderDeny() async throws {
        #expect(Self.selected(try await Self.headless(.approveReads).resolve(Self.request())) == "reject")
        let allowOnly = [PermissionOption(optionId: "allow", name: "Allow", kind: .allowOnce)]
        let response = try await Self.headless(.approveReads).resolve(Self.request(options: allowOnly))
        #expect(response.outcome == .cancelled)
    }

    @Test func anythingElseFailsUnderFail() async {
        await #expect(throws: PermissionPromptUnavailableError()) {
            _ = try await Self.headless(.approveReads, .fail).resolve(Self.request())
        }
        #expect(PermissionPromptUnavailableError().description
            == "Permission prompt unavailable in non-interactive mode")
    }

    @Test func theOtherModesNeverAsk() async throws {
        #expect(Self.selected(try await Self.headless(.approveAll, .fail).resolve(Self.request())) == "allow")
        #expect(Self.selected(try await Self.headless(.denyAll, .fail).resolve(Self.request(kind: .read))) == "reject")
        let noOptions = try await Self.headless(.approveAll).resolve(Self.request(options: []))
        #expect(noOptions.outcome == .cancelled)
    }

    // MARK: Through the connection

    /// An agent that asks permission for an edit, then says what it was answered.
    struct PermissionProbeAgent: ACPAgentHandler {
        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(agentInfo: Implementation(name: "permission-probe", version: "1.0"))
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: "permission-session")
        }

        func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
            let response = try await session.requestPermission(
                toolCall: ToolCallUpdate(toolCallId: "t1", title: "Edit notes.txt", kind: .edit),
                options: ToolPermissionApprovalTests.options)
            switch response.outcome {
            case .selected(let optionId): await session.sendText("selected:\(optionId)")
            default: await session.sendText("cancelled")
            }
            return PromptResponse(stopReason: .endTurn)
        }
    }

    /// Under `fail` the agent is answered `cancelled`, and the turn carries the
    /// unanswerable question, which fails it once over.
    @Test func anUnanswerableQuestionIsCancelledAndFailsTheTurn() async throws {
        let gate = WriteGateTests()
        let run = try await gate.run(
            PermissionProbeAgent(), cwd: try gate.workspace(),
            handlers: .standard(permission: .approveReads, nonInteractivePermissions: .fail, terminal: .none))
        #expect(run.reply == "cancelled")
        #expect(run.stats.cancelled == 1)
        #expect(run.stats.promptUnavailable)
    }

    @Test func underDenyTheQuestionIsRefused() async throws {
        let gate = WriteGateTests()
        let run = try await gate.run(
            PermissionProbeAgent(), cwd: try gate.workspace(),
            handlers: .standard(permission: .approveReads, terminal: .none))
        #expect(run.reply == "selected:reject")
        #expect(run.stats.denied == 1)
        #expect(!run.stats.promptUnavailable)
    }

    // MARK: With a terminal

    @Test func theTerminalIsAskedInAcpxsWords() async throws {
        for (typed, expected) in [("y\n", "allow"), ("yes\n", "allow"), ("n\n", "reject"), ("\n", "reject")] {
            let terminal = TerminalPermissionPromptTests.Terminal()
            terminal.type(typed)
            let approval = ToolPermissionApproval(policy: .approveReads, nonInteractive: .fail, terminal: terminal.prompt)
            let response = try await approval.resolve(Self.request())
            #expect(Self.selected(response) == expected, "\(typed)")
            await terminal.waitFor("(y/N) ")
            #expect(terminal.output.hasPrefix("\n[permission] Allow Edit notes.txt [edit]? (y/N) "), "\(typed)")
        }
    }

    /// No title is asked about as `tool`, of kind `other`.
    @Test func anUntitledToolIsAskedAboutAsTool() async throws {
        let terminal = TerminalPermissionPromptTests.Terminal()
        terminal.type("n\n")
        _ = try await ToolPermissionApproval(policy: .approveReads, terminal: terminal.prompt)
            .resolve(Self.request(title: nil, kind: nil))
        await terminal.waitFor("(y/N) ")
        #expect(terminal.output == "\n[permission] Allow tool [other]? (y/N) ")
    }
}
