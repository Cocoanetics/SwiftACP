@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// acpx 0.19.4's drain after a shell action's exit (openclaw/acpx#813, `test/flows-shell-admission.test.ts`
/// and `docs/flows.md`): the action's result comes at its wrapper's `close`, or 100 ms after its `exit`,
/// whichever is first — so the wrapper's last writes, and a descendant's within that window, are the
/// action's output, while a descendant that keeps the inherited pipes does not hold the step.
struct FlowShellDrainTests {
    /// A shell action's result driven on its own steps, as acpx's test drives a synthetic child.
    private static func drive(
        mode: FlowShellProcess.Mode, _ steps: @escaping @Sendable (FlowShellRun) -> Void
    ) async throws -> FlowShellResult {
        let closed = FlowShellEvent()
        let termination = FlowShellTermination(
            pid: 0, closed: closed, timeoutMs: nil, control: FlowShellControl(), onCleanupFailure: { _ in })
        let result: FlowShellResult = try await withCheckedThrowingContinuation { continuation in
            let run = FlowShellRun(
                spec: FlowShellExecution(json: .object([("command", .text("synthetic-child"))])), args: [], cwd: "/",
                startMs: FlowShellClock.nowMs(), mode: mode, closed: closed, termination: termination,
                first: FirstResult(continuation))
            steps(run)
        }
        try await termination.dispose()
        return result
    }

    /// acpx: "shell actions capture output delivered between exit and close": the exit, then a
    /// last write to each pipe, then their close — all of it the result.
    @Test(.timeLimit(.minutes(1))) func aShellActionsResultTakesWhatComesBetweenItsExitAndItsClose() async throws {
        let result = try await Self.drive(mode: .node) { run in
            run.exited(0)
            run.chunk(.stdout, Array("last stdout".utf8))
            run.chunk(.stderr, Array("last stderr".utf8))
            run.streamClosed(.stdout)
            run.streamClosed(.stderr)
        }
        #expect(result.combinedOutput == "last stdoutlast stderr")
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
    }

    /// A pipe kept open past the exit holds the result for the drain alone, acpx's 100 ms, with
    /// what came within it; `runShell`'s result still waits for the close.
    @Test(.timeLimit(.minutes(1))) func aShellActionsResultWaitsForItsPipesOnlyThroughTheDrain() async throws {
        let started = ContinuousClock.now
        let result = try await Self.drive(mode: .node) { run in
            run.exited(0)
            run.chunk(.stdout, Array("within the drain".utf8))
        }
        #expect(result.stdout == "within the drain")
        #expect(ContinuousClock.now - started >= .milliseconds(100))
        let command = try await Self.drive(mode: .command) { run in
            run.exited(0)
            run.chunk(.stdout, Array("before the close".utf8))
            run.streamClosed(.stdout)
            run.streamClosed(.stderr)
        }
        #expect(command.stdout == "before the close")
    }

    /// Through the runner: what a descendant writes to the wrapper's pipes after the wrapper
    /// has exited is the action's output, while the pipes close within the drain — lengthened
    /// here, so a loaded machine cannot cut it short. The descendant writes once the wrapper
    /// is gone, and a while after, which a result taken at the exit would never hold.
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func aShellActionDrainsWhatFollowsItsExit() async throws {
        let run = try await FlowShellRun.$drainWindow.withValue(.seconds(30)) {
            try await FlowRunnerHarness.run("""
                export default defineFlow({ name: "drained", startAt: "a", nodes: {
                  a: shell({ exec: () => ({ command: "/bin/sh", args: ["-c", "printf early; "
                    + "( while kill -0 $$ 2>/dev/null; do :; done; sleep 0.2; printf 'last stdout'; "
                    + "printf 'last stderr' >&2 ) & exit 0"] }),
                    parse: (r) => [r.stdout, r.stderr, r.combinedOutput] }) },
                  edges: [] });
                """)
        }
        #expect(run.code == 0, "\(run.err)")
        #expect(FlowRunnerHarness.member(run.state, "outputs", "a")
            == .array([.text("earlylast stdout"), .text("last stderr"), .text("earlylast stdoutlast stderr")]))
    }

    /// A descendant that keeps the pipes holds a shell action for the drain alone: the step
    /// completes with what came by then, as acpx's does.
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func aDescendantKeepingThePipesHoldsAShellActionOnlyThroughTheDrain() async throws {
        let scratch = try FIFOReader.make()
        let pidFile = scratch.directory.appendingPathComponent("pid")
        let run = try await FlowRunnerHarness.run("""
            const pidFile = \(WireJSON.text(pidFile.path).stringified);
            export default defineFlow({ name: "held-pipes", startAt: "a", nodes: {
              a: shell({ exec: () => ({ command: "/bin/sh", args: ["-c",
                `printf early; ( sleep 1000 & printf $! > ${JSON.stringify(pidFile)}; wait ) & exit 0`] }),
                parse: (r) => [r.combinedOutput, r.exitCode] }) },
              edges: [] });
            """)
        let sleeper = pid_t((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "")
        defer { if let sleeper { kill(sleeper, SIGKILL) } }
        #expect(run.code == 0, "\(run.err)")
        #expect(FlowRunnerHarness.member(run.state, "outputs", "a") == .array([.text("early"), .number(0)]))
        #expect(sleeper != nil, "the descendant's pid was not written")
    }
}
