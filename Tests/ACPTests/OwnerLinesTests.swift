@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// Under `--verbose`, the line acpx 0.19.3's CLI writes when it hands a request to the session's
/// running owner (#232): a prompt, which acpxd always takes as acpx's owner does, and a cancel or
/// a control while acpxd holds the session as an owner. None when no owner holds it, nor without
/// `--verbose`. The pid is acpxd's — here the test's own, which a stand-in daemon runs in.
@Suite(.serialized, .agentLane) struct OwnerLinesTests {
    struct Run {
        var code: Int32
        var out: String
        var err: String
        /// Both, as written.
        var merged: String
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func requestsAnOwnerTakesAreNoted() async throws {
        let agent = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        try await Self.inScope(agent) { id, run in
            let pid = ProcessInfo.processInfo.processIdentifier
            // No owner holds the session yet: the control runs as acpx's direct control does.
            #expect(!(await run(["--verbose", "set-mode", "plan"])).err.contains("owner pid"))
            #expect(!(await run(["--verbose", "cancel"])).err.contains("owner pid"))
            let prompt = await run(["--verbose", "prompt", "hi"])
            #expect(prompt.err.contains("[acpx] queued prompt on active owner pid \(pid) for session \(id)\n"))
            // The prompt left its owner holding the session.
            let control = await run(["--verbose", "set-mode", "plan"])
            #expect(control.err.contains(
                "[acpx] requested session/set_mode on owner pid \(pid) for session \(id)\n"))
            let cancel = await run(["--verbose", "cancel"])
            #expect(cancel.err.contains("[acpx] requested cancel on active owner pid \(pid) for session \(id)\n"))
            #expect(!(await run(["set-mode", "plan"])).err.contains("owner pid"))
        }
    }

    /// The prompt's line comes once the owner has the turn's result, as acpx's CLI writes it
    /// when `submitToQueueOwner` resolves: after the turn's output — its `[done]` — and never
    /// for a turn that failed.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func thePromptsLineFollowsItsResult() async throws {
        let agent = "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_EXIT_ON_PROMPT=2 " + (try #require(mockCommand()))
        try await Self.inScope(agent) { id, run in
            let line = "[acpx] queued prompt on active owner pid \(ProcessInfo.processInfo.processIdentifier)"
                + " for session \(id)\n"
            let answered = await run(["--verbose", "prompt", "hi"])
            #expect(answered.code == 0)
            #expect(answered.merged.hasSuffix("[done] end_turn\n" + line))
            let failed = await run(["--verbose", "prompt", "hi"])
            #expect(failed.code != 0)
            #expect(!failed.err.contains("owner pid"))
        }
    }

    /// `set model` and `set <option>`, each with its own line.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aModelOrAnOptionSetOnTheOwnerIsNoted() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py")
        try await Self.inScope("/usr/bin/env MODEL_AGENT_LOAD=1 '\(python)' '\(fixture.path)'") { id, run in
            let pid = ProcessInfo.processInfo.processIdentifier
            _ = await run(["prompt", "hi"])
            let model = await run(["--verbose", "set", "model", "m2"])
            #expect(model.err.contains(
                "[acpx] requested a model config update on owner pid \(pid) for session \(id)\n"))
            let option = await run(["--verbose", "set", "effort", "high"])
            #expect(option.err.contains(
                "[acpx] requested session/set_config_option on owner pid \(pid) for session \(id)\n"))
        }
    }

    /// The pid of the owner that ran the control goes with its result only when one did: the
    /// result reads the same to a CLI from before.
    @Test func theOwnerThatRanTheControlIsNamedOnlyWhenOneDid() throws {
        let owned = try JSONEncoder().encode(SessionControlResult(resumed: false, ownerPid: 42))
        #expect(Self.keys(owned) == ["ownerPid": 42, "resumed": false])
        let direct = try JSONEncoder().encode(SessionControlResult(resumed: true))
        #expect(String(decoding: direct, as: UTF8.self) == #"{"resumed":true}"#)
        #expect(try JSONDecoder().decode(SessionControlResult.self, from: owned).ownerPid == 42)
        #expect(try JSONDecoder().decode(SessionControlResult.self, from: direct).ownerPid == nil)
    }

    /// So does the pid of the owner that took a cancel, and the reply of a daemon from before —
    /// whether it cancelled, alone — still reads, as taken by none.
    @Test func theOwnerThatTookTheCancelIsNamedOnlyWhenOneDid() throws {
        let owned = try JSONEncoder().encode(SessionCancelResult(cancelled: true, ownerPid: 42))
        #expect(Self.keys(owned) == ["cancelled": true, "ownerPid": 42])
        let unowned = try JSONEncoder().encode(SessionCancelResult(cancelled: false))
        #expect(String(decoding: unowned, as: UTF8.self) == #"{"cancelled":false}"#)
        #expect(try JSONDecoder().decode(SessionCancelResult.self, from: owned)
            == SessionCancelResult(cancelled: true, ownerPid: 42))
        #expect(try JSONDecoder().decode(SessionCancelResult.self, from: Data("true".utf8))
            == SessionCancelResult(cancelled: true))
        #expect(try JSONDecoder().decode(SessionCancelResult.self, from: Data("false".utf8))
            == SessionCancelResult(cancelled: false))
    }

    /// A cancel's reply names the owner that took it as it took it, and a cancel for the
    /// caller's own turn (`turnToken`) none: acpx's CLI hands only a plain cancel to the owner.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCancelsReplyNamesTheOwnerThatTookIt() async throws {
        let agent = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await backend.newSession(agentCommand: agent, cwd: NSTemporaryDirectory())
            let pid = Int(ProcessInfo.processInfo.processIdentifier)
            #expect(try await backend.cancelSessionReportingOwner(sessionId: id, turnToken: nil).ownerPid == nil)
            _ = try await backend.runPrompt(sessionId: id, text: "hi")
            #expect(try await backend.cancelSessionReportingOwner(sessionId: id, turnToken: nil).ownerPid == pid)
            #expect(try await backend.cancelSessionReportingOwner(sessionId: id, turnToken: "t").ownerPid == nil)
            await backend.releaseAll()
            #expect(try await backend.cancelSessionReportingOwner(sessionId: id, turnToken: nil).ownerPid == nil)
        }
    }

    /// `data`'s top-level keys and values, whatever order they were written in.
    private static func keys(_ data: Data) -> [String: JSONValue] {
        (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
    }

    /// A session made for `agent` in a scratch scope, and `body` given its id and a way to run the
    /// CLI there against a stand-in acpxd.
    private static func inScope(
        _ agent: String, _ body: (String, (_ args: [String]) async -> Run) async throws -> Void
    ) async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let created = await acpx(["--format", "quiet", "sessions", "new"], agent: agent, cwd: directory)
            let id = created.out.trimmingCharacters(in: .whitespacesAndNewlines)
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            try await body(id) { await acpx($0, agent: agent, cwd: directory, daemon: daemon) }
            await backend.releaseAll()
        }
    }

    /// `acpx --approve-all --agent <agent> --cwd <cwd> <args>`, with `daemon` the one running.
    private static func acpx(
        _ args: [String], agent: String, cwd: URL, daemon: MCPServerConfig? = nil
    ) async -> Run {
        let capture = Console.Capture()
        let code: Int32 = await onThreadOfItsOwn {
            DaemonClient.$standIn.withValue(daemon) {
                Console.$capture.withValue(capture) {
                    runCommandLine(["--approve-all", "--agent", agent, "--cwd", cwd.path] + args)
                }
            }
        }
        return Run(code: code, out: capture.out, err: capture.err, merged: capture.merged)
    }
}
