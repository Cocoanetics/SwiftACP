@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// codex-acp's typed session failures (`_meta.jetbrains.air.sessionFailure`, #300): decoded, kept
/// whole, declared to the Codex adapter alone, and a terminal one ends a prompt as a failure.
struct SessionFailureTests {
    static let overloaded: JSONValue = .object([
        "jetbrains": .object(["air": .object([
            "version": .integer(1),
            "sessionFailure": .object([
                "id": .string("f1"), "revision": .integer(2), "category": .string("service"),
                "severity": .string("error"), "title": .string("Selected model is at capacity"),
                "kind": .string("overloaded"), "actions": .array([.string("retry")]), "extra": .bool(true)
            ])
        ])])
    ])

    @Test func theFailureIsDecodedWithEveryField() throws {
        let failure = try #require(SessionFailure(meta: Self.overloaded))
        #expect(failure.id == "f1" && failure.revision == 2 && failure.category == "service")
        #expect(failure.severity == "error" && failure.kind == "overloaded")
        #expect(failure.title == "Selected model is at capacity" && failure.actions == ["retry"])
        #expect(failure.isRetryable && !failure.isWarning)
        guard case .object(let raw) = failure.raw else { Issue.record("raw is not an object"); return }
        #expect(raw["extra"] == .bool(true))
        let bare: JSONValue = .object(["jetbrains": .object(["air": .object(["version": .integer(1)])])])
        #expect(SessionFailure(meta: bare) == nil)
        #expect(SessionFailure(meta: nil) == nil)
    }

    @Test func aResponseAndAnUpdateCarryTheFailure() throws {
        let response = PromptResponse(stopReason: .endTurn, meta: Self.overloaded)
        #expect(response.sessionFailure?.kind == "overloaded")
        #expect(throws: SessionFailureError.self) { _ = try response.throwingSessionFailure() }
        _ = try PromptResponse(stopReason: .endTurn).throwingSessionFailure()
        let update = SessionUpdate.other(
            kind: "session_info_update",
            payload: .object(["sessionUpdate": .string("session_info_update"), "_meta": Self.overloaded]))
        #expect(update.sessionFailure?.isRetryable == true)
    }

    @Test func retryFollowsTheOfferedAction() {
        #expect(PromptRetry.isRetryable(SessionFailureError(SessionFailure(actions: ["retry"]))))
        #expect(!PromptRetry.isRetryable(SessionFailureError(SessionFailure(actions: ["upgrade"]))))
    }

    @Test func theDeclarationIsMergedAndOnlyOptedIn() {
        #expect(ClientCapabilities.acpx(ClientOptions()).meta == nil)
        let declared = ClientCapabilities.acpx(ClientOptions(sessionFailures: true))
        #expect(declared.declaresSessionFailures)
        #expect(!declared.withoutSessionFailures().declaresSessionFailures)
        #expect(declared.withoutSessionFailures().meta == nil)
    }

    @Test func onlyTheCodexAdapterIsToldOfIt() async {
        let capabilities = ClientCapabilities.acpx.reportingSessionFailures()
        func plan(_ executable: String, _ arguments: [String]) async -> ClientCapabilities {
            var spec = ProcessLaunch(executable: executable, arguments: arguments)
            return await AgentLaunchCompat.Plan(
                &spec, limits: nil, clientInfo: .acpx, capabilities: capabilities, callerEnvironment: [:],
                probe: { _, _, _ in nil }).capabilities
        }
        #expect(await plan("npx", ["-y", "@agentclientprotocol/codex-acp@^2.2.2"]).declaresSessionFailures)
        #expect(await plan("/usr/local/bin/codex-acp", []).declaresSessionFailures)
        #expect(!(await plan("claude-agent-acp", []).declaresSessionFailures))
    }
}

extension DaemonToolsTests {
    /// An overloaded failure the agent reports on an `end_turn` response is a failed turn, not a
    /// completed one; with `--prompt-retries` it is sent again — the failure's own
    /// `session_info_update` is not an effect — and a failure the agent offers no retry for is not.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anOverloadedFailureOnAnEndTurnFailsTheTurn() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("air-overloaded-once")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await #expect(throws: SessionFailureError.self) {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: CallingClient())
            }
            #expect(session.prompts == 1)
            try session.set("air-overloaded-once")
            let text = try await limitedPrompt(
                daemon, session.id, limits: PromptLimits(promptRetries: 1), client: CallingClient())
            #expect(text == "hello")
            #expect(session.prompts == 2)
            await daemon.releaseAll()
        }
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aFailureWithoutARetryIsThrownAndNotRetried() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("air-quota")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let error = await #expect(throws: SessionFailureError.self) {
                try await limitedPrompt(
                    daemon, session.id, limits: PromptLimits(promptRetries: 2), client: CallingClient())
            }
            #expect(error?.failure.kind == "quota_exhausted")
            #expect(session.prompts == 1)
            await daemon.releaseAll()
        }
    }

    /// A `willRetry` warning stays a warning: the turn ends as the agent says.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aWarningDoesNotFailTheTurn() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("air-warning")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let text = try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: CallingClient())
            #expect(text == "hello")
            await daemon.releaseAll()
        }
    }
}
