@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// `sessions new` and `sessions ensure` give each step of making the session `--timeout`, as
/// acpx 0.19.3's `createSessionRecordWithClient` times the client's start, `session/new` or the
/// resume, and the model's selection (#247). Each expected output is what acpx printed for the
/// same agent (`Fixtures/retry-agent.py`).
struct SessionCreationTimeoutTests {
    struct Run {
        var code: Int32
        var out: String
        var err: String
        /// The agent's process, which should be gone once the command returns.
        var pid: pid_t?
        /// The records the command left.
        var records: Int
    }

    /// `acpx --format <format> --approve-all --timeout 60 --agent <retry-agent in mode> <args>`.
    /// The deadlines waiting as the agent gets the request it holds pass then
    /// (``DeadlineSource``): with the timeout as long as the test may take, one that never
    /// passes fails the test.
    private func acpx(_ mode: String, _ args: [String], format: String = "text") async throws -> Run {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-agent.py")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("creation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready")
        let pidFile = dir.appendingPathComponent("pid")
        let deadlines = DeadlineSource()
        let watch = try ExecInterruptTests.whenWritten(to: ready) { deadlines.fire() }
        defer { watch.cancel() }
        let agent = "/usr/bin/env RETRY_AGENT_MODE=\(mode) RETRY_AGENT_READY='\(ready.path)' "
            + "RETRY_AGENT_PID='\(pidFile.path)' '\(python)' '\(fixture.path)'"
        let arguments = ["--format", format, "--cwd", dir.path, "--approve-all", "--timeout", "60", "--agent", agent]
            + args
        return await withIsolatedStore {
            let capture = Console.Capture()
            // The command blocks its thread until it is done, as the CLI does: a thread of its own.
            let code: Int32 = await withCheckedContinuation { continuation in
                Thread {
                    let code = Console.$capture.withValue(capture) {
                        DeadlineSource.$current.withValue(deadlines) { runCommandLine(arguments) }
                    }
                    continuation.resume(returning: code)
                }.start()
            }
            let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0) }
            return Run(
                code: code, out: capture.out, err: capture.err, pid: pid, records: SessionStore.listSessions().count)
        }
    }

    private func isRunning(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return kill(pid, 0) == 0
    }

    /// A step of making a session that the fixture holds up.
    struct Step: Sendable, CustomTestStringConvertible {
        var mode: String
        var args: [String] = ["sessions", "new"]
        var testDescription: String { "\(mode) \(args.joined(separator: " "))" }
    }

    private static let timeoutHint =
        "hint: increase `--timeout <seconds>` for long-running prompts, or check whether the agent/provider is stalled."

    /// Starting the agent, `session/new` and the model each have `--timeout` to themselves,
    /// in `sessions ensure` too, and one that runs over fails the command as `TIMEOUT` (exit 3)
    /// with no session made. The agent is put down by the time the command returns, as acpx
    /// closes the client it started — even one that never finished starting.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: [
        Step(mode: "hang-init"),
        Step(mode: "hang-new"),
        Step(mode: "hang-model", args: ["--model", "b", "sessions", "new"]),
        Step(mode: "hang-new", args: ["sessions", "ensure"])
    ])
    func aStepThatRunsOverTimesOut(step: Step) async throws {
        let run = try await acpx(step.mode, step.args)
        #expect(run.code == ExitCodes.timeout)
        #expect(run.out.isEmpty)
        #expect(run.err == "Timed out after 60000ms\n\(Self.timeoutHint)\n")
        #expect(run.records == 0)
        #expect(run.pid != nil)
        #expect(!isRunning(run.pid), "the agent outlived the command")
    }

    /// A resume past the timeout is the resume's failure, as acpx words it: a runtime error,
    /// with the hints for a load that failed.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aResumePastTheTimeoutFailsTheResume() async throws {
        let run = try await acpx("hang-load", ["sessions", "new", "--resume-session", "abc"])
        #expect(run.code == ExitCodes.error)
        #expect(run.out.isEmpty)
        #expect(run.err == """
            Failed to resume ACP session abc: Timed out after 60000ms
            hint: rerun with `--verbose` to capture the ACP load failure details.
            hint: if you do not need the old backend session, start a fresh one with `acpx <agent> sessions new` \
            and retry.

            """)
        #expect(run.records == 0)
        #expect(!isRunning(run.pid), "the agent outlived the command")
    }

    /// In JSON, the timeout is one JSON-RPC error line, as acpx prints it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTimeoutIsOneErrorLineInJSON() async throws {
        let run = try await acpx("hang-init", ["sessions", "new"], format: "json")
        #expect(run.code == ExitCodes.timeout)
        #expect(run.out == #"""
            {"jsonrpc":"2.0","id":null,"error":{"code":-32070,"message":"Timed out after 60000ms",\#
            "data":{"acpxCode":"TIMEOUT","origin":"cli","sessionId":"unknown"}}}

            """#)
        #expect(run.err.isEmpty)
    }
}
