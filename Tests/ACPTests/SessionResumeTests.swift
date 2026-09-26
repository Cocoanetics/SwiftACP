@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// `sessions new --resume-session <id>` and `sessions ensure --resume-session <id>` take
/// the session back instead of starting one, as acpx's `createSession` does: with
/// `session/resume` when the agent advertises it, else `session/load`, refused by an agent
/// that can do neither. An open record under that id is closed first (acpx 0.19.3, #782).
/// Each output is what acpx printed for the same steps on `mock-agent.py`.
@Suite(.serialized) struct SessionResumeTests {
    struct Run {
        var code: Int32
        var out: String
        var err: String
    }

    /// The mock agent, its `session/load` answering as `load` says, logging what it is sent.
    private static func agent(load: String, log: URL, environment: String = "") throws -> String {
        let command = try #require(mockCommand())
        return "/usr/bin/env MOCK_REQUEST_LOG='\(log.path)' MOCK_SESSION_ID_PER_PROCESS=1 "
            + "MOCK_LOAD_SESSION=\(load) \(environment)\(command)"
    }

    /// `acpx --approve-all --agent <agent> --cwd <cwd> <args>`, with `daemon` the one running.
    private static func acpx(
        _ args: [String], agent: String, cwd: URL, daemon: MCPServerConfig? = nil
    ) async -> Run {
        let capture = Console.Capture()
        let code: Int32 = await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: DaemonClient.$standIn.withValue(daemon) {
                    Console.$capture.withValue(capture) {
                        runCommandLine(["--approve-all", "--agent", agent, "--cwd", cwd.path] + args)
                    }
                })
            }.start()
        }
        return Run(code: code, out: capture.out, err: capture.err)
    }

    /// Each `session/…` request `log` holds, with the session it names.
    private static func requests(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = message["method"] as? String, method.hasPrefix("session/")
            else { return nil }
            let session = (message["params"] as? [String: Any])?["sessionId"] as? String
            return session.map { "\(method) \($0)" } ?? method
        }
    }

    private static func directories() throws -> (URL, URL) {
        let root = try DaemonToolsTests.scratchDirectory()
        for name in ["a", "b"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return (root.appendingPathComponent("a"), root.appendingPathComponent("b"))
    }

    /// Resuming the scope's own session takes it back under its id: one record, open.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theScopesOwnSessionIsTakenBack() async throws {
        let (a, _) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let log = a.appendingPathComponent("requests.ndjson")
        let agent = try Self.agent(load: "ok", log: log)
        try await withIsolatedStore {
            let first = await Self.acpx(["--format", "quiet", "sessions", "new"], agent: agent, cwd: a)
            let id = first.out.trimmingCharacters(in: .whitespacesAndNewlines)
            let resumed = await Self.acpx(["sessions", "new", "--resume-session", id], agent: agent, cwd: a)
            #expect(resumed.code == 0)
            #expect(resumed.out == "\(id)\t(replaced \(id))\n")
            #expect(Self.requests(log) == ["session/new", "session/load \(id)"])
            #expect(SessionStore.listSessions().map(\.acpxRecordId) == [id])
            #expect(SessionStore.loadRecord(id)?.closed != true)
        }
    }

    /// A session another scope has is closed there first, and taken back here, under its id.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anotherScopesSessionMovesHere() async throws {
        let (a, b) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let log = a.appendingPathComponent("requests.ndjson")
        let agent = try Self.agent(load: "ok", log: log)
        try await withIsolatedStore {
            let id = await Self.acpx(["--format", "quiet", "sessions", "new"], agent: agent, cwd: a).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resumed = await Self.acpx(["sessions", "new", "--resume-session", id], agent: agent, cwd: b)
            #expect(resumed.code == 0)
            #expect(resumed.out == "\(id)\n")
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.closed != true)
            #expect(URL(fileURLWithPath: record.cwd).lastPathComponent == "b")
            #expect(SessionStore.listSessions().count == 1)
        }
    }

    /// `sessions ensure` resumes the session when the scope has none.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func ensureResumesWhenTheScopeHasNone() async throws {
        let (a, _) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let log = a.appendingPathComponent("requests.ndjson")
        let agent = try Self.agent(load: "ok", log: log)
        try await withIsolatedStore {
            let run = await Self.acpx(["sessions", "ensure", "--resume-session", "kept-1"], agent: agent, cwd: a)
            #expect(run.code == 0)
            #expect(run.out == "kept-1\t(created)\n")
            #expect(Self.requests(log) == ["session/load kept-1"])
        }
    }

    /// A session the agent no longer has fails the resume as `NO_SESSION`, and writes no record.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionTheAgentLostIsNoSession() async throws {
        let (a, _) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let agent = try Self.agent(load: "gone", log: a.appendingPathComponent("requests.ndjson"))
        try await withIsolatedStore {
            let text = await Self.acpx(["sessions", "new", "--resume-session", "lost-1"], agent: agent, cwd: a)
            #expect(text.code == 4)
            #expect(text.err == """
                Failed to resume ACP session lost-1: Resource not found: session lost-1
                hint: the saved ACP session is missing or stale; start a fresh session with \
                `acpx <agent> sessions new`, then retry.

                """)
            let json = await Self.acpx(
                ["--format", "json", "sessions", "new", "--resume-session", "lost-1"], agent: agent, cwd: a)
            #expect(json.code == 4)
            #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32002,"#
                + #""message":"Resource not found: session lost-1","data":{"acpxCode":"NO_SESSION","#
                + #""origin":"cli","sessionId":"unknown"}}}"# + "\n")
            #expect(SessionStore.listSessions().isEmpty)
        }
    }

    /// The agent's not-found code makes it `NO_SESSION` whatever its message says: the agent's
    /// error is the resume's cause, as acpx's `extractAcpError` finds it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aNotFoundCodeIsNoSessionWhateverItsMessage() async throws {
        let (a, _) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let agent = try Self.agent(
            load: "error", log: a.appendingPathComponent("requests.ndjson"),
            environment: #"MOCK_LOAD_ERROR='{"code":-32002,"message":"Session gone"}' "#)
        try await withIsolatedStore {
            let run = await Self.acpx(["sessions", "new", "--resume-session", "x-1"], agent: agent, cwd: a)
            #expect(run.code == 4)
            #expect(run.err == """
                Failed to resume ACP session x-1: Session gone
                hint: the saved ACP session is missing or stale; start a fresh session with \
                `acpx <agent> sessions new`, then retry.

                """)
        }
    }

    /// A requested model the resumed session refuses as gone fails the resume the same way:
    /// the model control's error is the resume's cause, and the agent's error is behind it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aModelRefusedAsGoneMakesTheResumeNoSession() async throws {
        let (a, _) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py")
        let agent = "/usr/bin/env MODEL_AGENT_LOAD=1 MODEL_AGENT_LEGACY=1 "
            + #"MODEL_AGENT_MODEL_ERROR='{"code":-32002,"message":"Session gone"}' "#
            + "'\(python)' '\(fixture.path)'"
        try await withIsolatedStore {
            let run = await Self.acpx(
                ["--model", "m2", "sessions", "new", "--resume-session", "old-1"], agent: agent, cwd: a)
            #expect(run.code == 4)
            #expect(run.err == """
                Failed to resume ACP session old-1: Failed session/set_model for model "m2": Session gone \
                (ACP -32002)
                hint: the saved ACP session is missing or stale; start a fresh session with \
                `acpx <agent> sessions new`, then retry.

                """)
        }
    }

    /// The agent's own failure fails the resume as a runtime error, with the hints for one.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anAgentsFailureFailsTheResume() async throws {
        let (a, _) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let agent = try Self.agent(load: "internal", log: a.appendingPathComponent("requests.ndjson"))
        try await withIsolatedStore {
            let run = await Self.acpx(["sessions", "new", "--resume-session", "x-1"], agent: agent, cwd: a)
            #expect(run.code == 1)
            #expect(run.err == """
                Failed to resume ACP session x-1: Internal error
                hint: rerun with `--verbose` to capture the ACP load failure details.
                hint: if you do not need the old backend session, start a fresh one with \
                `acpx <agent> sessions new` and retry.

                """)
        }
    }

    /// An agent that can neither resume nor load a session is refused before it is asked.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anAgentThatCannotLoadIsRefused() async throws {
        let (a, _) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let log = a.appendingPathComponent("requests.ndjson")
        let agent = try Self.agent(load: "unsupported", log: log)
        try await withIsolatedStore {
            let run = await Self.acpx(["sessions", "new", "--resume-session", "x-1"], agent: agent, cwd: a)
            #expect(run.code == 1)
            #expect(run.err == """
                Agent command "\(agent)" does not support session/resume or session/load; cannot resume \
                session x-1
                hint: this adapter cannot resume saved ACP sessions; create a fresh one with \
                `acpx <agent> sessions new` instead of reusing `--resume-session`.

                """)
            #expect(Self.requests(log).isEmpty)
        }
    }

    /// A session a daemon holds is closed there before it is taken back: its agent goes, and
    /// the session resumed is open.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aHeldSessionIsClosedBeforeItIsTakenBack() async throws {
        let (a, _) = try Self.directories()
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        let agent = try Self.agent(load: "ok", log: a.appendingPathComponent("requests.ndjson"))
        try await withIsolatedStore {
            let id = await Self.acpx(["--format", "quiet", "sessions", "new"], agent: agent, cwd: a).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await backend.runPrompt(sessionId: id, text: "hi")
            let held = try #require(await backend.heldConnection(id))

            let resumed = await Self.acpx(
                ["sessions", "new", "--resume-session", id], agent: agent, cwd: a,
                daemon: .stdioHandles(server: ACPXDaemon(backend: backend)))
            #expect(resumed.code == 0)
            let letGo = await (try? withTimeout(milliseconds: 10_000) { await held.waitUntilClosed() }) != nil
            #expect(letGo, "the resumed session's old agent is still running")
            #expect(SessionStore.loadRecord(id)?.closed != true)
            await backend.releaseAll()
        }
    }
}
