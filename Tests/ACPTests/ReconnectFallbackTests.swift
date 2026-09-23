@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// How a restarted daemon gets a session back (issue #52), as acpx decides it:
/// resume if advertised, else load if advertised, else a new session — and a failed
/// load is replaced by a new session only when that loses nothing worth keeping.
/// The mock's `MOCK_LOAD_SESSION` picks how it answers `session/load`.
extension DaemonToolsTests {
    /// Runs `body` with the mock (in `loadMode`) logging the session requests it gets.
    /// `forgetAfterPrompts` makes each mock process drop its sessions after that many
    /// answered prompts; `exitAfterPrompts` makes it exit.
    func withLoggedMock(
        loadMode: String, forgetAfterPrompts: Int = 0, exitAfterPrompts: Int = 0,
        _ body: (_ command: String, _ methods: () throws -> [String]) async throws -> Void
    ) async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try FileManager.default.createDirectory(
                at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            let logged =
                "/usr/bin/env MOCK_LOAD_SESSION=\(loadMode) MOCK_FORGET_AFTER_PROMPTS=\(forgetAfterPrompts) "
                + "MOCK_EXIT_AFTER_PROMPTS=\(exitAfterPrompts) MOCK_REQUEST_LOG='\(log.path)' \(command)"
            try await body(logged) {
                try String(contentsOf: log, encoding: .utf8)
                    .split(separator: "\n")
                    .compactMap {
                        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                    }
                    .compactMap { $0["method"] as? String }
            }
        }
    }

    /// An agent that never advertised `loadSession` is not asked to load — it gets a
    /// new session straight away. An agent that ignores unknown methods would
    /// otherwise hang the turn.
    @Test(.enabled(if: mockPythonAvailable))
    func anAgentThatCannotLoadIsNeverAskedTo() async throws {
        try await withLoggedMock(loadMode: "unsupported") { command, methods in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let answer = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .runPrompt(sessionId: id, text: "ping")
            #expect(!answer.isEmpty)
            #expect(!(try methods()).contains("session/load"))
            #expect((try methods()).filter { $0 == "session/new" }.count == 2)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aSessionTheAgentStillHasIsTakenBack() async throws {
        try await withLoggedMock(loadMode: "ok") { command, methods in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "ping")
            #expect((try methods()).contains("session/load"))
            // Loaded, so no second session was started in its place.
            #expect((try methods()).filter { $0 == "session/new" }.count == 1)
        }
    }

    /// A session the agent no longer has is replaced — there is nothing left to keep.
    @Test(.enabled(if: mockPythonAvailable))
    func aSessionTheAgentNoLongerHasIsReplaced() async throws {
        try await withLoggedMock(loadMode: "gone") { command, methods in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            let answer = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .runPrompt(sessionId: id, text: "second")
            #expect(!answer.isEmpty)
            #expect((try methods()).suffix(3).first == "session/load")
        }
    }

    /// A generic internal error does not justify swapping a real conversation for an
    /// empty one under the same id: the failure is reported instead.
    @Test(.enabled(if: mockPythonAvailable))
    func anInternalErrorDoesNotReplaceAConversation() async throws {
        try await withLoggedMock(loadMode: "internal") { command, methods in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            #expect(SessionStore.loadRecord(id)?.hasAgentMessages == true)

            let before = (try methods()).filter { $0 == "session/new" }.count
            await #expect(throws: (any Error).self) {
                _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                    .runPrompt(sessionId: id, text: "second")
            }
            #expect((try methods()).filter { $0 == "session/new" }.count == before)
        }
    }

    /// …while a session with no conversation yet has nothing to lose, so it may be.
    @Test(.enabled(if: mockPythonAvailable))
    func anInternalErrorMayReplaceAnEmptySession() async throws {
        try await withLoggedMock(loadMode: "internal") { command, _ in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            #expect(SessionStore.loadRecord(id)?.hasAgentMessages == false)
            let answer = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .runPrompt(sessionId: id, text: "ping")
            #expect(!answer.isEmpty)
        }
    }

    /// A session imported from another client must stay the same session; acpx's
    /// `sameSessionOnly` refuses rather than replacing it.
    @Test(.enabled(if: mockPythonAvailable))
    func anImportedSessionIsNeverReplaced() async throws {
        try await withLoggedMock(loadMode: "gone") { command, methods in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            try markImported(id)

            let error = await #expect(throws: DaemonError.self) {
                _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                    .runPrompt(sessionId: id, text: "ping")
            }
            #expect(error?.localizedDescription.hasPrefix(
                "Persistent ACP session \(id) could not be resumed: Resource not found") == true)
            #expect((try methods()).filter { $0 == "session/new" }.count == 1)
            // The agent's answer is final: the refusal reads like a gone session, but
            // it must not send the turn round again to launch and ask a second time.
            #expect((try methods()).filter { $0 == "session/load" }.count == 1)
        }
    }

    /// …nor when the agent cannot take any session back: it is refused outright, in
    /// acpx's words, without a `session/load` or a new session.
    @Test(.enabled(if: mockPythonAvailable))
    func anImportedSessionIsRefusedByAnAgentThatCannotLoad() async throws {
        try await withLoggedMock(loadMode: "unsupported") { command, methods in
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            try markImported(id)

            let error = await #expect(throws: DaemonError.self) {
                _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                    .runPrompt(sessionId: id, text: "ping")
            }
            #expect(error?.localizedDescription == "Persistent ACP session \(id) could not be resumed: "
                + "agent does not support session/resume or session/load")
            #expect(try methods() == ["session/new"])
        }
    }

    /// Marks a session as imported from another client, as `sessions import` does.
    private func markImported(_ id: String) throws {
        var record = try #require(SessionStore.loadRecord(id))
        record.importedFrom = SessionRecord.ImportedFrom(
            recordId: "elsewhere", cwdOriginal: "/elsewhere", exportedBy: "acpx",
            exportedAt: "2026-09-23T00:00:00.000Z")
        try SessionStore.writeRecord(record)
    }

    /// A session the daemon already holds can still vanish — the agent drops it — and
    /// then the turn goes round once more on a fresh launch, which takes it back.
    @Test(.enabled(if: mockPythonAvailable))
    func aHeldSessionTheAgentDropsIsTakenBack() async throws {
        try await withLoggedMock(loadMode: "ok", forgetAfterPrompts: 1) { command, methods in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            let answer = try await daemon.runPrompt(sessionId: id, text: "second")
            #expect(!answer.isEmpty)
            // `newSession` leaves no agent running (like acpx's `sessions new`), so the
            // first turn loads the session; the second finds it dropped, relaunches,
            // loads it again and asks once more.
            #expect(try methods() == [
                "session/new", "session/load", "session/prompt",
                "session/prompt", "session/load", "session/prompt"
            ])
        }
    }

    /// The refusal names the reason in acpx's words, however the error is caught.
    @Test func anUnsupportedReconnectSaysWhy() {
        let error: any Error = SessionReconnectUnsupported()
        #expect(error.localizedDescription == "agent does not support session/resume or session/load")
    }

    // MARK: - The rule itself

    /// acpx's order: cancellation first (it is not the agent's answer, even for an
    /// imported session), then the imported-session refusal, then the fallback rule.
    @Test func whatAFailedReconnectLeadsTo() {
        let notFound = JSONRPCErrorBody(code: -32002, message: "Resource not found")
        let internalError = JSONRPCErrorBody(code: -32603, message: "Internal error")
        func outcome(_ error: Error, imported: Bool = false, messages: Bool = true) -> ReconnectFallback.Outcome {
            ReconnectFallback.outcome(after: error, sameSessionOnly: imported, sessionHasAgentMessages: messages)
        }
        #expect(outcome(CancellationError(), imported: true) == .surface)
        #expect(outcome(CancellationError()) == .surface)
        #expect(outcome(notFound, imported: true) == .refuse)
        #expect(outcome(SessionReconnectUnsupported(), imported: true) == .refuse)
        #expect(outcome(SessionReconnectUnsupported()) == .startFresh)
        #expect(outcome(notFound) == .startFresh)
        #expect(outcome(internalError) == .surface)
        #expect(outcome(internalError, messages: false) == .startFresh)
    }

    @Test func whichFailuresMayStartOver() {
        let notFound = JSONRPCErrorBody(code: -32002, message: "Resource not found")
        let unsupported = JSONRPCErrorBody(code: -32601, message: "Method not found")
        let badParams = JSONRPCErrorBody(code: -32602, message: "Invalid params")
        let internalError = JSONRPCErrorBody(code: -32603, message: "Internal error")
        let other = JSONRPCErrorBody(code: -32000, message: "Authentication required")

        #expect(ReconnectFallback.shouldStartFresh(after: notFound, sessionHasAgentMessages: true))
        #expect(ReconnectFallback.shouldStartFresh(after: unsupported, sessionHasAgentMessages: true))
        #expect(ReconnectFallback.shouldStartFresh(after: badParams, sessionHasAgentMessages: true))
        #expect(!ReconnectFallback.shouldStartFresh(after: internalError, sessionHasAgentMessages: true))
        #expect(ReconnectFallback.shouldStartFresh(after: internalError, sessionHasAgentMessages: false))
        #expect(!ReconnectFallback.shouldStartFresh(after: other, sessionHasAgentMessages: false))
        #expect(!ReconnectFallback.shouldStartFresh(after: CancellationError(), sessionHasAgentMessages: false))
    }

    /// acpx recognises a gone session by code, by wording, or by wording buried in the
    /// error's data.
    @Test func aGoneSessionIsRecognisedHoweverItIsSaid() {
        #expect(ReconnectFallback.isResourceNotFound(JSONRPCErrorBody(code: -32001, message: "x")))
        #expect(ReconnectFallback.isResourceNotFound(
            JSONRPCErrorBody(code: -32000, message: "Session \"abc-123\" not found")))
        #expect(ReconnectFallback.isResourceNotFound(
            JSONRPCErrorBody(code: -32000, message: "Unknown session")))
        #expect(ReconnectFallback.isResourceNotFound(JSONRPCErrorBody(
            code: -32603, message: "Internal error",
            data: .object(["details": .object(["cause": .string("invalid session identifier")])]))))
        #expect(!ReconnectFallback.isResourceNotFound(
            JSONRPCErrorBody(code: -32603, message: "Internal error")))
    }
}
