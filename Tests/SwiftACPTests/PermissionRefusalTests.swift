import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// The Codex refusal compatibility rule (openclaw/acpx#535, fixed in #608): a
/// permission refusal must never end the turn by accident. Pure checks on
/// ``CodexCompat`` and the response metadata, plus loopback turns through the real
/// client — the same scenario table acpx's `client.test.ts` runs.
struct PermissionRefusalTests {
    static let codex = CodexCompat.agentName

    /// A Codex-shaped request: `allow` first, then the given `reject_once` ids.
    static func request(_ refusalIds: [String], kind: ToolKind = .execute) -> RequestPermissionRequest {
        RequestPermissionRequest(
            sessionId: "s",
            toolCall: ToolCallUpdate(toolCallId: "1", title: "synthetic operation", kind: kind),
            options: [PermissionOption(optionId: "allow", name: "Yes, proceed", kind: .allowOnce)]
                + refusalIds.map { PermissionOption(optionId: $0, name: $0, kind: .rejectOnce) })
    }

    // MARK: - CodexCompat (pure)

    @Test func ranksCodexContinuingRefusalFirst() {
        let raw = Self.request(["cancel", "decline"])
        let ranked = CodexCompat.preferPermissionRefusal(raw, agentName: Self.codex)
        #expect(ranked.options.map(\.optionId) == ["decline", "allow", "cancel"])
        // Kind-based selection now lands on the refusal that lets the turn continue…
        #expect(PermissionPolicy.reject(ranked).outcome == .selected(optionId: "decline"))
        // …where the raw order would have aborted the whole turn (the bug).
        #expect(PermissionPolicy.reject(raw).outcome == .selected(optionId: "cancel"))
        // Approvals are untouched by the ranking.
        #expect(PermissionPolicy.approve(ranked).outcome == .selected(optionId: "allow"))
    }

    @Test func ranksRejectPermissionsToo() {
        let ranked = CodexCompat.preferPermissionRefusal(
            Self.request(["cancel", "reject_permissions"]), agentName: Self.codex)
        #expect(ranked.options.first?.optionId == "reject_permissions")
    }

    @Test func leavesOtherAdaptersAndUnrankableRequestsAlone() {
        let raw = Self.request(["cancel", "decline"])
        let rawIds = raw.options.map(\.optionId)
        // Another adapter's option ids are opaque — never reordered.
        let unrelated = CodexCompat.preferPermissionRefusal(raw, agentName: "unrelated-adapter")
        #expect(unrelated.options.map(\.optionId) == rawIds)
        #expect(CodexCompat.preferPermissionRefusal(raw, agentName: nil).options.map(\.optionId) == rawIds)
        // Codex offering only the aborting refusal (a sandbox escalation) stays as is.
        let abortOnly = Self.request(["cancel"])
        #expect(CodexCompat.preferPermissionRefusal(abortOnly, agentName: Self.codex).options == abortOnly.options)
        // Only a `reject_once` `decline` counts — the id alone doesn't.
        var oddKind = Self.request(["cancel"])
        oddKind.options.append(PermissionOption(optionId: "decline", name: "decline", kind: .allowAlways))
        #expect(CodexCompat.preferPermissionRefusal(oddKind, agentName: Self.codex).options == oddKind.options)
    }

    @Test func noticeExplainsOnlyAbortiveCodexRefusals() {
        let request = Self.request(["cancel", "decline"])
        let cancelNotice = CodexCompat.permissionNotice(
            request: request, response: .selected("cancel"), agentName: Self.codex)
        #expect(cancelNotice?.contains("can end the current turn") == true)
        #expect(cancelNotice?.contains("was not approved") == true)
        let cancelledNotice = CodexCompat.permissionNotice(
            request: request, response: .cancelled, agentName: Self.codex)
        #expect(cancelledNotice?.contains("No matching permission option") == true)
        #expect(cancelledNotice?.contains("may end the current turn") == true)

        // A refusal that continues the turn, an approval, or another adapter: nothing to explain.
        func notice(_ response: RequestPermissionResponse, agent: String? = Self.codex) -> String? {
            CodexCompat.permissionNotice(request: request, response: response, agentName: agent)
        }
        #expect(notice(.selected("decline")) == nil)
        #expect(notice(.selected("allow")) == nil)
        #expect(notice(.selected("cancel"), agent: "unrelated") == nil)
        #expect(notice(.cancelled, agent: nil) == nil)
        // `cancel` is only Codex's abort when it is a `reject_once` option.
        var allowNamedCancel = Self.request([])
        allowNamedCancel.options = [PermissionOption(optionId: "cancel", name: "Allow", kind: .allowOnce)]
        #expect(CodexCompat.permissionNotice(
            request: allowNamedCancel, response: .selected("cancel"), agentName: Self.codex) == nil)
    }

    // MARK: - Response metadata

    @Test func metadataMergesUnderACPXAndRoundTrips() throws {
        let existing = RequestPermissionResponse(
            outcome: .selected(optionId: "cancel"),
            meta: .object([
                "vendor": .string("kept"),
                "acpx": .object(["permissionEscalation": .object(["action": .string("escalate")])])
            ]))
        let explained = existing.addingACPXMetadata(["permissionNotice": .string("may end the turn")])
        #expect(explained.permissionNotice == "may end the turn")
        #expect(explained.meta?["vendor"]?.stringValue == "kept")
        #expect(explained.meta?["acpx"]?["permissionEscalation"]?["action"]?.stringValue == "escalate")
        // The original is untouched (value semantics), and a bare response has no notice.
        #expect(existing.permissionNotice == nil)
        #expect(RequestPermissionResponse.cancelled.permissionNotice == nil)

        // On the wire the metadata rides under `_meta` and decodes back.
        let json = try String(decoding: JSONEncoder().encode(explained), as: UTF8.self)
        #expect(json.contains("\"_meta\""))
        let decoded = try JSONDecoder().decode(RequestPermissionResponse.self, from: Data(json.utf8))
        #expect(decoded.outcome == .selected(optionId: "cancel"))
        #expect(decoded.permissionNotice == "may end the turn")
        // A response without metadata encodes without the key at all.
        let bare = try JSONEncoder().encode(RequestPermissionResponse.selected("allow"))
        #expect(!String(decoding: bare, as: UTF8.self).contains("_meta"))
    }

    // MARK: - Loopback turns through the real client

    /// An agent that identifies as `agentName` and, when prompted, asks permission
    /// for one tool offering `allow` plus the given `reject_once` ids, then reports
    /// the client's answer as text: `selected:<id>` or `cancelled`, followed by
    /// `|notice:<text>` when the response carried `_meta.acpx.permissionNotice`.
    struct ProbeAgent: ACPAgentHandler {
        var agentName: String
        var refusalIds: [String]
        var toolKind: ToolKind = .execute
        /// Antigravity marks an interaction question by prefixing this — see
        /// ``AntigravityCompat`` and `AntigravityQuestionTests`.
        var toolCallId: String = "synthetic-call"

        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(agentInfo: Implementation(name: agentName, version: "1.12.0"))
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: "probe-session")
        }

        func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
            let options = [PermissionOption(optionId: "allow", name: "Allow", kind: .allowOnce)]
                + refusalIds.map { PermissionOption(optionId: $0, name: $0, kind: .rejectOnce) }
            let response = try await session.requestPermission(
                toolCall: ToolCallUpdate(toolCallId: toolCallId, title: "synthetic operation", kind: toolKind),
                options: options)
            switch response.outcome {
            case .selected(let optionId): await session.sendText("selected:\(optionId)")
            case .cancelled: await session.sendText("cancelled")
            }
            if let notice = response.permissionNotice { await session.sendText("|notice:\(notice)") }
            return PromptResponse(stopReason: .endTurn)
        }
    }

    /// What one probe turn produced: the agent's report of the answer it received,
    /// the notice it saw on the wire (if any), and the client operations the
    /// connection reported to its subscribers.
    struct Probe {
        var answer: String
        var echoedNotice: String?
        var operations: [ClientOperation]
    }

    static func runProbe(_ agent: ProbeAgent, policy: PermissionPolicy) async throws -> Probe {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: agent, transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(
            transport: clientTransport, handlers: .standard(permission: policy))
        await client.start()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))

        // The event subscription carries updates and client operations in wire order;
        // the operation is reported before the agent can react to the answer.
        let (subscriptionId, stream) = await client.makeEventSubscription()
        let consumer = Task { () -> (String, [ClientOperation]) in
            var text = ""
            var operations: [ClientOperation] = []
            for await event in stream {
                switch event {
                case .update(let note):
                    if case .agentMessageChunk(let block) = note.update, let chunk = block.text { text += chunk }
                case .clientOperation(let operation):
                    operations.append(operation)
                }
            }
            return (text, operations)
        }
        let response = try await client.prompt(
            PromptRequest(sessionId: session.sessionId, prompt: [.text("go")]))
        #expect(response.stopReason == .endTurn)
        await client.endSubscription(subscriptionId)
        let (text, operations) = await consumer.value
        await client.close()
        serverTask.cancel()

        let parts = text.components(separatedBy: "|notice:")
        return Probe(answer: parts[0], echoedNotice: parts.count > 1 ? parts[1] : nil, operations: operations)
    }

    /// How the client answers: a built-in mode, or a host resolver (acpx's
    /// `onPermissionRequest`) deciding by kind or cancelling outright.
    enum Mode: Sendable {
        case denyAll, approveAll, approveReads, hostReject, hostCancel

        var policy: PermissionPolicy {
            switch self {
            case .denyAll: return .denyAll
            case .approveAll: return .approveAll
            case .approveReads: return .approveReads
            case .hostReject: return .custom { PermissionPolicy.reject($0) }
            case .hostCancel: return .custom { _ in .cancelled }
            }
        }
    }

    struct Scenario: Sendable, CustomTestStringConvertible {
        var name: String
        var ids: [String]
        var mode: Mode = .denyAll
        var agent: String = PermissionRefusalTests.codex
        var kind: ToolKind = .execute
        /// The option the client should select; `nil` means the request is cancelled.
        var expected: String?
        var notice = false
        var testDescription: String { name }
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "mode denial", ids: ["cancel", "decline"], expected: "decline"),
        Scenario(name: "automatic approval", ids: ["cancel", "decline"], mode: .approveAll, expected: "allow"),
        Scenario(name: "noninteractive denial", ids: ["cancel", "decline"], mode: .approveReads, expected: "decline"),
        Scenario(
            name: "read auto-approval", ids: ["cancel", "decline"], mode: .approveReads, kind: .read,
            expected: "allow"),
        Scenario(
            name: "permission-profile refusal", ids: ["cancel", "reject_permissions"],
            expected: "reject_permissions"),
        Scenario(name: "already ordered denial", ids: ["decline", "cancel"], expected: "decline"),
        Scenario(name: "host denial", ids: ["cancel", "decline"], mode: .hostReject, expected: "decline"),
        Scenario(name: "abort-only refusal", ids: ["cancel"], expected: "cancel", notice: true),
        Scenario(name: "host abort-only refusal", ids: ["cancel"], mode: .hostReject, expected: "cancel", notice: true),
        Scenario(name: "missing refusal", ids: [], expected: nil, notice: true),
        Scenario(name: "explicit host cancellation", ids: ["cancel", "decline"], mode: .hostCancel, expected: nil),
        Scenario(name: "unrelated adapter", ids: ["cancel", "decline"], agent: "unrelated-adapter", expected: "cancel"),
        Scenario(name: "unrelated adapter abort-only", ids: ["cancel"], agent: "unrelated-adapter", expected: "cancel")
    ]

    @Test(arguments: scenarios)
    func routesCodexPermissionThroughACP(_ scenario: Scenario) async throws {
        let probe = try await Self.runProbe(
            ProbeAgent(agentName: scenario.agent, refusalIds: scenario.ids, toolKind: scenario.kind),
            policy: scenario.mode.policy)

        #expect(probe.answer == scenario.expected.map { "selected:\($0)" } ?? "cancelled")

        if scenario.notice {
            // Explained once: as a completed client operation for the permission
            // method, and as `_meta.acpx.permissionNotice` the agent saw on the wire.
            #expect(probe.operations.count == 1)
            let operation = try #require(probe.operations.first)
            #expect(operation.method == ClientOperation.requestPermission)
            #expect(operation.status == .completed)
            #expect(operation.sessionId == "probe-session")
            #expect(operation.summary.lowercased().contains("cancel"))
            #expect(operation.summary.lowercased().contains("turn"))
            #expect(probe.echoedNotice == operation.summary)
        } else {
            #expect(probe.operations.isEmpty)
            #expect(probe.echoedNotice == nil)
        }
    }

    @Test func hostResolverReceivesTheRankedRequest() async throws {
        // A custom resolver is handed the ranked request (unlike acpx, whose host
        // decides by kind only and never sees option ids), so a resolver that takes
        // the first refusal — or renders the options in order — is safe too.
        actor Seen { var ids: [String] = []; func record(_ ids: [String]) { self.ids = ids } }
        let seen = Seen()
        let probe = try await Self.runProbe(
            ProbeAgent(agentName: Self.codex, refusalIds: ["cancel", "decline"]),
            policy: .custom { request in
                await seen.record(request.options.map(\.optionId))
                let firstRefusal = request.options.first { $0.kind == .rejectOnce }
                return firstRefusal.map { .selected($0.optionId) } ?? .cancelled
            })
        #expect(await seen.ids == ["decline", "allow", "cancel"])
        #expect(probe.answer == "selected:decline")
        #expect(probe.operations.isEmpty)
    }
}
