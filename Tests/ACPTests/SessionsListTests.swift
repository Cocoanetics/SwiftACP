@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// `sessions` asks the agent over `session/list` when it advertises it, as acpx 0.19.3's
/// `handleSessionsList` does, and prints its answer as it came — else, with `--local`, or when
/// the agent cannot be spawned, the local records (#244). Each expected output is what acpx
/// printed for the same answer.
@Suite(.serialized, .agentLane) struct SessionsListTests {
    struct Run {
        var code: Int32
        var out: String
        var err: String
        /// The `params` of each `session/list` the agent got.
        var listed: [String]
    }

    /// `acpx --approve-all --cwd <dir> --agent <mock answering session/list with reply> <args>`;
    /// without a reply, the agent does not advertise `session/list`. Run in the store of the test
    /// calling it (``withIsolatedStore``).
    private func acpx(_ args: [String], reply: String?, agent: String? = nil) async throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("requests.ndjson")
        let command = try agent ?? "/usr/bin/env MOCK_REQUEST_LOG='\(log.path)' "
            + (reply.map { "MOCK_LIST_REPLY='\($0)' " } ?? "") + #require(mockCommand())
        let arguments = ["--approve-all", "--cwd", dir.path, "--agent", command] + args
        let capture = Console.Capture()
        // The command blocks its thread until it is done, as the CLI does: a thread of its own.
        let code: Int32 = await onThreadOfItsOwn {
            Console.$capture.withValue(capture) { runCommandLine(arguments) }
        }
        let requests = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let listed = requests.split(separator: "\n").compactMap { line -> String? in
            guard let message = WireJSON(parsing: Data(line.utf8)),
                  message["method"]?.stringValue == "session/list"
            else { return nil }
            return (message["params"] ?? .null).stringified
                .replacingOccurrences(of: dir.path, with: "<DIR>")
        }
        return Run(code: code, out: capture.out, err: capture.err, listed: listed)
    }

    private static let answer = #"{"_meta":{"z":1,"a":2},"nextCursor":"c2","extra":true,"sessions":["#
        + #"{"cwd":"/w/a","extra":1,"sessionId":"agent-a","_meta":{"z":1,"a":2},"#
        + #""updatedAt":"2026-09-01T00:00:00Z","title":"First"},{"sessionId":"agent-b","cwd":"/w/b","title":null}]}"#

    /// The agent's answer is printed as it came: in JSON with its own members, in their order;
    /// as one line per session in text, with the cursor to go on from; as the ids in quiet.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theAgentsAnswerIsPrintedAsItCame() async throws { try await withIsolatedStore {
        let json = try await acpx(["--format", "json", "sessions"], reply: Self.answer)
        #expect(json.code == ExitCodes.success)
        #expect(json.out == #"{"_meta":{"z":1,"a":2},"source":"agent","sessions":[{"cwd":"/w/a","extra":1,"#
            + #""sessionId":"agent-a","_meta":{"z":1,"a":2},"updatedAt":"2026-09-01T00:00:00Z","title":"First"},"#
            + #"{"sessionId":"agent-b","cwd":"/w/b","title":null}],"nextCursor":"c2"}"# + "\n")
        #expect(json.listed == ["{}"])
        let text = try await acpx(["sessions", "list"], reply: Self.answer)
        #expect(text.out == """
            agent-a\tFirst\t/w/a\t2026-09-01T00:00:00Z\t{"z":1,"a":2}
            agent-b\t-\t/w/b\t-\t-
            Next cursor: c2

            """)
        let quiet = try await acpx(["--format", "quiet", "sessions"], reply: Self.answer)
        #expect(quiet.out == "agent-a\nagent-b\n")
    } }

    /// `--cursor` and `--filter-cwd` go to the agent — the directory resolved — and come back in
    /// the result, as acpx's `listAgentSessions` gives them.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theCursorAndTheDirectoryGoToTheAgent() async throws { try await withIsolatedStore {
        let run = try await acpx(
            ["--format", "json", "sessions", "--cursor", "c1", "--filter-cwd", "sub"],
            reply: #"{"sessions":[{"sessionId":"x","cwd":"/w"}]}"#)
        #expect(run.code == ExitCodes.success)
        let params = try #require(run.listed.first.flatMap { WireJSON(parsing: Data($0.utf8)) })
        #expect(params["cwd"]?.stringValue == "<DIR>/sub")
        #expect(params["cursor"]?.stringValue == "c1")
        let expected = #"{"source":"agent","sessions":[{"sessionId":"x","cwd":"/w"}],"cursor":"c1","cwd":""#
        #expect(run.out.hasPrefix(expected))
        #expect(run.out.hasSuffix(#"/sub"}"# + "\n"))
    } }

    /// An agent that does not advertise `session/list` has its local records listed — unless
    /// the listing asks for what only the agent could give; `--local` never asks it, and refuses
    /// a cursor.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func withoutSessionListTheLocalRecordsAreListed() async throws { try await withIsolatedStore {
        let plain = try await acpx(["sessions"], reply: nil)
        #expect(plain.code == ExitCodes.success)
        #expect(plain.out == "No sessions\n")
        #expect(plain.listed.isEmpty)
        let filtered = try await acpx(["sessions", "--cursor", "c1"], reply: nil)
        #expect(filtered.code == ExitCodes.error)
        #expect(filtered.err.contains(
            "does not advertise sessionCapabilities.list; cannot use agent-side session/list filters"))
        let local = try await acpx(["sessions", "--local", "--cursor", "c1"], reply: Self.answer)
        #expect(local.code == ExitCodes.usage)
        #expect(local.err.contains("--cursor cannot be combined with --local"))
        #expect(local.listed.isEmpty)
        let unspawned = try await acpx(["sessions", "--cursor", "c1"], reply: nil, agent: "/nonexistent/agent")
        #expect(unspawned.code == ExitCodes.success)
        #expect(unspawned.out == "No sessions\n")
    } }

    /// An answer of the wrong shape is read as JavaScript reads it: a member missing prints as
    /// `undefined`, other values as a template literal prints them, and a list that is not there
    /// fails as the TypeError acpx's printing raises.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anAnswerOfTheWrongShapeIsReadAsJavaScriptReadsIt() async throws { try await withIsolatedStore {
        let odd = #"{"sessions":[5,{"sessionId":null,"cwd":[1,[2,null]],"title":null,"updatedAt":false,"_meta":0}],"#
            + #""nextCursor":{"a":1}}"#
        let text = try await acpx(["sessions"], reply: odd)
        #expect(text.out == "undefined\t-\tundefined\t-\t-\nnull\t-\t1,2,\tfalse\t-\nNext cursor: [object Object]\n")
        let missing = try await acpx(["sessions"], reply: "{}")
        #expect(missing.code == ExitCodes.error)
        #expect(missing.err == "Cannot read properties of undefined (reading 'length')\n")
        let quiet = try await acpx(["--format", "quiet", "sessions"], reply: #"{"sessions":[null]}"#)
        #expect(quiet.code == ExitCodes.error)
        #expect(quiet.err == "[acpx] error: RUNTIME Cannot read properties of null (reading 'sessionId')\n")
        let json = try await acpx(["--format", "json", "sessions"], reply: "{}")
        #expect(json.code == ExitCodes.success)
        #expect(json.out == #"{"source":"agent"}"# + "\n")
    } }

    /// `acpx --approve-all --cwd <dir> --agent <retry-agent in mode> sessions`, signalled as the
    /// agent gets `initialize` when `interrupting`; the code, stderr, and the agent's pid.
    private func listRetryAgent(_ mode: String, interrupting: Bool) async throws -> Stopped {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-agent.py")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid")
        let ready = dir.appendingPathComponent("ready")
        let source = Interrupts.Source()
        let watch = interrupting ? try ExecInterruptTests.fire(source, whenWrittenTo: ready) : nil
        defer { watch?.cancel() }
        let agent = "/usr/bin/env RETRY_AGENT_MODE=\(mode) RETRY_AGENT_PID='\(pidFile.path)' "
            + (interrupting ? "RETRY_AGENT_READY='\(ready.path)' " : "") + "'\(python)' '\(fixture.path)'"
        let arguments = ["--approve-all", "--cwd", dir.path, "--agent", agent, "sessions"]
        let capture = Console.Capture()
        let code: Int32 = await onThreadOfItsOwn {
            Console.$capture.withValue(capture) {
                Interrupts.$source.withValue(interrupting ? source : nil) { runCommandLine(arguments) }
            }
        }
        let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0) }
        return Stopped(code: code, err: capture.err, pid: pid)
    }

    /// How a listing ended, and the agent it started.
    struct Stopped {
        var code: Int32
        var err: String
        var pid: pid_t?
    }

    /// The agent is closed before the listing is over, as acpx closes its client (`finally`): it
    /// is gone by the time the command returns (#258 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theAgentIsGoneWhenTheListingIsOver() async throws { try await withIsolatedStore {
        let listed = try await listRetryAgent("ok", interrupting: false)
        #expect(listed.code == ExitCodes.success)
        let agent = try #require(listed.pid)
        #expect(kill(agent, 0) != 0, "the agent outlived the listing")
    } }

    /// A signal while the agent starts calls its launch off, the agent put down, and the listing
    /// ends `INTERRUPTED` without a word, as `exec` does (#258 review; #261 for acpx's own race).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSignalWhileTheAgentStartsPutsItDown() async throws { try await withIsolatedStore {
        let listed = try await listRetryAgent("hang-init", interrupting: true)
        #expect(listed.code == ExitCodes.interrupted)
        #expect(listed.err.isEmpty)
        let agent = try #require(listed.pid)
        #expect(kill(agent, 0) != 0, "the agent outlived the listing")
    } }
}
