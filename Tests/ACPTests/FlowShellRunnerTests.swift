@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// acpx 0.19.3's shell action and `ctx.runShell` cases for the runner (`test/flows.test.ts`,
/// `test/flows-managed-command.test.ts`), run by the runner with the flow's code in the
/// Node host. acpx's managed-command fixture moves its deadlines on mocked timers; here
/// they are real, and a command that must be ready before its deadline is a shell that
/// installs its `trap` first thing, with a deadline of 2 s, which a loaded machine starting
/// the shell cannot outrun.
struct FlowShellRunnerTests {
    private func runnerRun(_ body: String) async throws -> FlowRunnerHarness.Run {
        try await FlowRunnerHarness.run(body)
    }

    private func member(_ value: WireJSON?, _ path: String...) -> WireJSON? {
        path.reduce(value) { $0?[$1] }
    }

    /// A file for a test's command to write to, as a JavaScript string literal.
    private final class Scratch {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-shell-\(UUID().uuidString)")
        init() { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func path(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func js(_ name: String) -> String { WireJSON.text(path(name).path).stringified }
        func read(_ name: String) -> String? { try? String(contentsOf: path(name), encoding: .utf8) }
    }

    /// acpx: "FlowRunner executes native shell actions and parses structured output" — the
    /// step showing its command while it runs, traced before and after.
    @Test(.enabled(if: nodeAvailable))
    func aShellActionRunsItsCommandAndParsesTheResult() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "shell-test", startAt: "transform", nodes: {
              transform: shell({
                exec: () => ({ command: process.execPath,
                  args: ["-e", 'process.stdout.write(JSON.stringify({ok:true, value:"shell"}))'] }),
                parse: (result) => JSON.parse(result.stdout) }) },
              edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "transform")?.stringified == #"{"ok":true,"value":"shell"}"#)
        let types = run.trace.compactMap { $0["type"]?.stringValue }
        #expect(types == [
            "run_started", "node_started", "node_heartbeat", "action_prepared", "artifact_written", "artifact_written",
            "action_completed", "node_outcome", "run_completed"
        ])
        let status = run.trace.first { $0["type"] == .text("node_heartbeat") }?["payload"]?["statusDetail"]
        #expect(status?.stringValue?.hasPrefix("shell: ") == true)
    }

    /// acpx: "FlowRunner marks timed out shell steps explicitly".
    @Test(.enabled(if: nodeAvailable))
    func aShellCommandPastItsDeadlineTimesTheStepOut() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "timeout-test", startAt: "slow", nodes: {
              slow: shell({ exec: () => ({ command: process.execPath, args: ["-e", "setTimeout(() => {}, 1000)"],
                timeoutMs: 50 }) }) },
              edges: [] });
            """)
        #expect(run.code == 3)
        #expect(run.err == "Timed out after 50ms")
        #expect(member(run.state, "status") == .text("timed_out"))
        #expect(member(run.state, "results", "slow", "outcome") == .text("timed_out"))
        #expect(member(run.state, "results", "slow", "error") == .text("Timed out after 50ms"))
        #expect(member(run.state, "results", "slow", "nodeType") == .text("action"))
    }

    /// acpx: "FlowRunner preserves shell timeoutMs 0 as no action deadline" and "can route
    /// timed out nodes by outcome".
    @Test(.enabled(if: nodeAvailable))
    func aShellDeadlineIsItsOwnAndATimedOutStepRoutes() async throws {
        let zero = try await runnerRun("""
            export default defineFlow({ name: "timeout-zero-ok", startAt: "ok", nodes: {
              ok: shell({ exec: () => ({ command: process.execPath, args: ["-e", "setTimeout(() => {}, 80)"],
                timeoutMs: 0 }) }) },
              edges: [] });
            """)
        #expect(zero.code == 0, "\(zero.err)")
        let routed = try await runnerRun("""
            export default defineFlow({ name: "timeout-route-test", startAt: "slow", nodes: {
              slow: shell({ exec: () => ({ command: process.execPath, args: ["-e", "setTimeout(() => {}, 1000)"],
                timeoutMs: 50 }) }),
              after_timeout: action({ run: ({ results }) => ({ routed: true, outcome: results.slow?.outcome }) }) },
              edges: [{ from: "slow", switch: { on: "$result.outcome", cases: { timed_out: "after_timeout" } } }] });
            """)
        #expect(routed.code == 0, "\(routed.err)")
        #expect(member(routed.state, "outputs", "after_timeout")?.stringified
            == #"{"routed":true,"outcome":"timed_out"}"#)
    }

    /// acpx: "FlowRunner times out async shell exec callbacks" and "… parse callbacks".
    @Test(.enabled(if: nodeAvailable), arguments: [
        "exec: async () => await new Promise(() => {})",
        #"exec: () => ({ command: process.execPath, args: ["-e", 'process.stdout.write("ok")'] }), "#
            + "parse: async () => await new Promise(() => {})"
    ])
    func aShellCallbackThatNeverSettlesTimesOut(_ callbacks: String) async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "shell-callback-timeout", startAt: "slow", nodes: {
              slow: shell({ timeoutMs: 200, \(callbacks) }) }, edges: [] });
            """)
        #expect(run.code == 3, "\(run.err)")
        #expect(member(run.state, "results", "slow", "outcome") == .text("timed_out"))
    }

    /// A delay no clock can hold — a node's `timeoutMs` and `heartbeatMs`, and a command's
    /// `timeoutMs`, of 10²⁴ ms — is no timer: the run goes on as without one. acpx's Node
    /// runs such a timer after 1 ms and times the step out at once (openclaw/acpx#812).
    @Test(.enabled(if: nodeAvailable))
    func aDelayNoClockCanHoldTimesNothingOut() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "huge-delays", startAt: "a", nodes: {
              a: compute({ timeoutMs: 1e24, heartbeatMs: 1e24, run: () => "ran" }),
              b: shell({ timeoutMs: 1e24, exec: () => ({ command: "/bin/sh", args: ["-c", "true"], timeoutMs: 1e24 }),
                parse: (result) => result.exitCode }) },
              edges: [{ from: "a", to: "b" }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "b") == .number(0))
    }

    /// acpx: "FlowRunner does not launch a shell action when its executor resolves after
    /// timeout". The next node holds the host up past the executor's return.
    @Test(.enabled(if: nodeAvailable))
    func anExecResolvedPastTheDeadlineStartsNothing() async throws {
        let scratch = Scratch()
        let run = try await runnerRun("""
            export default defineFlow({ name: "late-executor", startAt: "late", nodes: {
              late: shell({ timeoutMs: 50, exec: async () => {
                await new Promise((resolve) => setTimeout(resolve, 200));
                const marker = \(scratch.js("marker"));
                return { command: process.execPath, timeoutMs: 0,
                  args: ["-e", `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'launched')`] };
              } }),
              after: compute({ run: () => new Promise((resolve) => setTimeout(() => resolve(1), 600)) }) },
              edges: [{ from: "late", switch: { on: "$result.outcome", cases: { timed_out: "after" } } }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(scratch.read("marker") == nil)
    }

    /// acpx: "function command returns ordinary nonzero diagnostics without ending the node".
    @Test(.enabled(if: nodeAvailable))
    func runShellReportsAFailingExitAndTheNodeGoesOn() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "run-shell", startAt: "a", nodes: {
              a: action({ run: async ({ runShell }) => {
                const r = await runShell({ command: process.execPath, args: ["-e",
                  'process.stdout.write("ordinary stdout"); process.stderr.write("ordinary stderr");'
                    + " process.exitCode = 7;"] });
                return { stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode, signal: r.signal,
                  timedOut: r.timedOut, keys: Object.keys(r) };
              } }) }, edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a")?.stringified
            == #"{"stdout":"ordinary stdout","stderr":"ordinary stderr","exitCode":7,"signal":null,"timedOut":false,"#
                + #""keys":["command","args","cwd","stdout","stderr","combinedOutput","exitCode","signal","#
                + #""durationMs","timedOut"]}"#)
    }

    /// acpx: "function command deadline escalates TERM and returns partial diagnostics".
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func runShellPastItsOwnDeadlineIsKilledAndReportsWhatItHad() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "run-shell-deadline", startAt: "a", nodes: {
              a: action({ run: async ({ runShell }) => {
                const r = await runShell({ command: "/bin/sh", timeoutMs: 2000, args: ["-c",
                  "trap '' TERM; printf 'partial stdout'; printf 'partial stderr' >&2; while :; do sleep 1; done"] });
                return { stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode, signal: r.signal,
                  timedOut: r.timedOut };
              } }) }, edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a")?.stringified
            == #"{"stdout":"partial stdout","stderr":"partial stderr","exitCode":null,"signal":"SIGKILL","#
                + #""timedOut":true}"#)
    }

    /// acpx: "successful function command waits for inherited streams after wrapper exit".
    @Test(.enabled(if: nodeAvailable))
    func runShellWaitsForWhatStillHoldsItsPipes() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "run-shell-close", startAt: "a", nodes: {
              a: action({ run: async ({ runShell }) => {
                const r = await runShell({ command: "/bin/sh", args: ["-c",
                  "printf 'early stdout'; (sleep 0.3; printf 'late stdout'; printf 'late stderr' >&2) & exit 0"] });
                return { stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode, timedOut: r.timedOut };
              } }) }, edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a")?.stringified
            == #"{"stdout":"early stdoutlate stdout","stderr":"late stderr","exitCode":0,"timedOut":false}"#)
    }

    /// acpx: "outer node timeout joins native cleanup and denies a caught callback's next
    /// command": the node's deadline stops the command — which saw the TERM — and fails
    /// `runShell` with the timeout, and the callback's next command with it too.
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func aNodeDeadlineStopsRunShellAndRefusesTheNext() async throws {
        let scratch = Scratch()
        let run = try await runnerRun("""
            import fs from "node:fs";
            export default defineFlow({ name: "outer-timeout", startAt: "a", nodes: {
              a: action({ timeoutMs: 2000, run: async ({ runShell, signal }) => {
                try {
                  const term = \(scratch.js("term"));
                  await runShell({ command: "/bin/sh", args: ["-c",
                    `trap 'printf term > ${JSON.stringify(term)}' TERM; while :; do sleep 0.1; done`] });
                } catch (error) {
                  const report = { first: `${error.name}: ${error.message}`, aborted: signal.aborted };
                  try {
                    await runShell({ command: "/bin/sh", args: ["-c", "true"] });
                    report.next = "dispatched";
                  } catch (next) {
                    report.next = `${next.name}: ${next.message}`;
                  }
                  fs.writeFileSync(\(scratch.js("report")), JSON.stringify(report));
                  throw error;
                }
              } }),
              after: compute({ run: () => new Promise((resolve) => setTimeout(() => resolve(1), 300)) }) },
              edges: [{ from: "a", switch: { on: "$result.outcome", cases: { timed_out: "after" } } }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "results", "a", "outcome") == .text("timed_out"))
        #expect(scratch.read("report") == #"{"first":"TimeoutError: Timed out after 2000ms","aborted":true,"#
            + #""next":"TimeoutError: Timed out after 2000ms"}"#)
        #expect(scratch.read("term") == "term")
    }

    /// acpx: "FlowRunner reaps shell child when outer node deadline expires".
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func aNodeDeadlineReapsItsShellCommand() async throws {
        let scratch = Scratch()
        let run = try await runnerRun("""
            export default defineFlow({ name: "shell-outer-timeout", startAt: "slow", nodes: {
              slow: shell({ timeoutMs: 2000, exec: () => ({ command: "/bin/sh", timeoutMs: 0, args: ["-c",
                `printf $$ > ${JSON.stringify(\(scratch.js("pid")))}; trap 'printf term > `
                  + `${JSON.stringify(\(scratch.js("term")))}' TERM; while :; do sleep 0.1; done`] }) }) },
              edges: [] });
            """)
        #expect(run.code == 3)
        #expect(member(run.state, "status") == .text("timed_out"))
        #expect(member(run.state, "results", "slow", "outcome") == .text("timed_out"))
        #expect(scratch.read("term") == "term")
        let pid = try #require(pid_t(scratch.read("pid") ?? ""))
        #expect(kill(pid, 0) != 0 || ProcessTable.snapshot()?[pid] == nil, "the shell \(pid) is still running")
    }

    /// acpx's `runCallbackShell` is `attempt.own(...)`, which refuses at once — a throw, not
    /// a rejection — for an attempt no longer taking work: a `runShell` kept past its
    /// attempt and called from the next node, as finished; and, for an attempt that
    /// failed, with the very value its callback threw, which its `signal` was aborted with.
    @Test(.enabled(if: nodeAvailable))
    func runShellAfterItsAttemptIsRefusedAtOnce() async throws {
        let run = try await runnerRun("""
            let kept, keptSignal;
            const boom = new Error("boom");
            const call = (expected) => {
              try {
                kept({ command: "/bin/sh", args: ["-c", "true"] });
                return "dispatched";
              } catch (error) {
                return { message: error.message, same: error === expected, reason: keptSignal.reason === error };
              }
            };
            export default defineFlow({ name: "kept-run-shell", startAt: "a", nodes: {
              a: action({ run: ({ runShell, signal }) => { kept = runShell; keptSignal = signal; return 1; } }),
              b: compute({ run: () => call(undefined) }),
              c: action({ run: ({ runShell, signal }) => { kept = runShell; keptSignal = signal; throw boom; } }),
              d: compute({ run: () => call(boom) }) },
              edges: [{ from: "a", to: "b" }, { from: "b", to: "c" },
                { from: "c", switch: { on: "$result.outcome", cases: { failed: "d" } } }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "b")?.stringified
            == #"{"message":"Flow attempt has finished accepting work","same":false,"reason":false}"#)
        #expect(member(run.state, "outputs", "d")?.stringified == #"{"message":"boom","same":true,"reason":true}"#)
    }

    /// The runner's own refusal, for a `runShell` sent before the host hears that its
    /// attempt is over: an attempt the runner has let go of refuses with the reason it
    /// stopped for — here its timeout — as acpx's attempt would; one that just finished,
    /// or one never known, as finished.
    @Test(.enabled(if: nodeAvailable))
    func aRetiredAttemptRefusesRunShellWithItsReason() async throws {
        let run = try await FlowRunnerHarness.run("""
            export default defineFlow({ name: "retired", startAt: "a", nodes: {
              a: action({ timeoutMs: 50, run: () => new Promise(() => {}) }),
              b: action({ run: () => 1 }) },
              edges: [{ from: "a", switch: { on: "$result.outcome", cases: { timed_out: "b" } } }] });
            """, probe: { runner in
                var refusals: [String] = []
                for attemptId in ["a#1", "b#1", "z#1"] {
                    let params: WireJSON = .object([
                        ("attemptId", .text(attemptId)), ("execution", .object([("command", .text("true"))]))
                    ])
                    do {
                        _ = try await runner.runCallbackShell(params)
                        refusals.append("ran")
                    } catch {
                        refusals.append(TurnFailureText.message(of: error))
                    }
                }
                return refusals.joined(separator: " | ")
            })
        #expect(run.code == 0, "\(run.err)")
        #expect(run.probed == "Timed out after 50ms | Flow attempt has finished accepting work"
            + " | Flow attempt has finished accepting work")
    }

    /// What `runShell` refuses, as acpx does: an execution it cannot read the `cwd` of, or
    /// whose `cwd` `path.resolve` refuses, at once; one Node's `spawn` refuses, as a
    /// rejection with the `TypeError` Node throws — its code, and its `toString` — and a
    /// command not found with the properties Node gives a spawn failure.
    @Test(.enabled(if: nodeAvailable))
    func runShellRefusesWhatNodeWouldAsNodeWould() async throws {
        let run = try await runnerRun("""
            const attempt = (runShell, execution) => {
              const describe = (error) => ({ name: error.name, code: error.code ?? null, text: String(error) });
              try {
                return runShell(execution).then(() => "resolved", (error) => ({ async: describe(error) }));
              } catch (error) {
                return { sync: describe(error) };
              }
            };
            export default defineFlow({ name: "refused-run-shell", startAt: "a", nodes: {
              a: action({ run: async ({ runShell }) => ({
                none: await attempt(runShell, undefined),
                cwd: await attempt(runShell, { command: "true", cwd: 5 }),
                file: await attempt(runShell, { args: [] }),
                empty: await attempt(runShell, { command: "" }),
                missing: await attempt(runShell, { command: "/nonexistent/tool" }),
                spawnargs: await runShell({ command: "/nonexistent/tool", args: ["x"] })
                  .catch((error) => [error.errno, error.syscall, error.path, error.spawnargs]),
              }) }) },
              edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        let outputs = try #require(member(run.state, "outputs", "a"))
        #expect(outputs["none"]?.stringified == #"{"sync":{"name":"TypeError","code":null,"#
            + #""text":"TypeError: Cannot read properties of undefined (reading 'cwd')"}}"#)
        #expect(outputs["cwd"]?.stringified == #"{"sync":{"name":"TypeError","code":"ERR_INVALID_ARG_TYPE","#
            + #""text":"TypeError [ERR_INVALID_ARG_TYPE]: The \"paths[1]\" argument must be of type string. "#
            + #"Received type number (5)"}}"#)
        #expect(outputs["file"]?.stringified == #"{"async":{"name":"TypeError","code":"ERR_INVALID_ARG_TYPE","#
            + #""text":"TypeError [ERR_INVALID_ARG_TYPE]: The \"file\" argument must be of type string. "#
            + #"Received undefined"}}"#)
        #expect(outputs["empty"]?.stringified == #"{"async":{"name":"TypeError","code":"ERR_INVALID_ARG_VALUE","#
            + #""text":"TypeError [ERR_INVALID_ARG_VALUE]: The argument 'file' cannot be empty. Received ''"}}"#)
        #expect(outputs["missing"]?.stringified == #"{"async":{"name":"Error","code":"ENOENT","#
            + #""text":"Error: spawn /nonexistent/tool ENOENT"}}"#)
        #expect(outputs["spawnargs"]?.stringified == #"[-2,"spawn /nonexistent/tool","/nonexistent/tool",["x"]]"#)
    }

    /// acpx's runner holds the flow's own values: a command gets each argument as Node's
    /// `spawn` converts it — `String(arg)`, an object by its own `toString`, or with `shell`
    /// as `Array.join` does — and its result holds the very list the flow gave.
    @Test(.enabled(if: nodeAvailable))
    func runShellGivesTheCommandItsArgumentsAsNodeDoes() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "argv", startAt: "a", nodes: {
              a: action({ run: async ({ runShell }) => {
                const own = { toString: () => "own" };
                const plain = { command: "/bin/echo", args: [undefined, null, 5, 5n, {}, [1, 2], true, own] };
                const one = await runShell(plain);
                const shelled = { command: "echo", args: [undefined, null, 7n, "x"], shell: true };
                const two = await runShell(shelled);
                return [one.stdout, one.args === plain.args, two.stdout, two.args === shelled.args];
              } }) },
              edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a")?.stringified
            == #"["undefined null 5 5 [object Object] 1,2 true own\n",true,"7 x\n",true]"#)
    }

    /// A shell action shows its arguments as `JSON.stringify` writes the flow's own values —
    /// a number bare, in its status and traces; `undefined` as `null` in its output — while
    /// `parse`, and later nodes, get them as the flow gave them. A BigInt command, which
    /// `JSON.stringify` refuses, fails the step at its trace, whose `seq` it took, as in acpx.
    @Test(.enabled(if: nodeAvailable))
    func aShellActionShowsItsArgumentsAsTheFlowGaveThem() async throws {
        let run = try await runnerRun("""
            let given;
            export default defineFlow({ name: "shown", startAt: "a", nodes: {
              a: shell({ exec: () => (given = ["-n", 5], { command: "/bin/echo", args: given }),
                parse: (r) => ({ out: r.stdout, same: r.args === given }) }),
              m: shell({ exec: () => ({ command: "/bin/echo", args: [undefined, 5] }) }),
              n: compute({ run: ({ outputs }) => typeof outputs.m.args[0] }),
              b: shell({ exec: () => ({ command: 5n, args: [] }) }) },
              edges: [{ from: "a", to: "m" }, { from: "m", to: "n" }, { from: "n", to: "b" }] });
            """)
        #expect(run.code == 1)
        #expect(run.err == "Do not know how to serialize a BigInt")
        #expect(member(run.state, "outputs", "a")?.stringified == #"{"out":"5","same":true}"#)
        #expect(member(run.state, "outputs", "m", "args")?.stringified == "[null,5]")
        #expect(member(run.state, "outputs", "n") == .text("undefined"))
        let status = run.trace.first { $0["type"] == .text("node_heartbeat") }?["payload"]?["statusDetail"]
        #expect(status == .text(#"shell: /bin/echo "-n" 5"#))
        let prepared = run.trace.first { $0["type"] == .text("action_prepared") }?["payload"]?["action"]?["args"]
        #expect(prepared?.stringified == #"["-n",5]"#)
        let tail = Array(run.trace.suffix(3))
        #expect(tail.compactMap { $0["type"]?.stringValue } == ["node_heartbeat", "node_outcome", "run_failed"])
        let seqs: [Double] = tail.compactMap { event in
            guard case .number(let seq)? = event["seq"] else { return nil }
            return seq
        }
        #expect(seqs.count == 3 && seqs[1] == seqs[0] + 2 && seqs[2] == seqs[1] + 1, "\(seqs)")
    }

    /// What JSON cannot carry reaches the runner as acpx's runner sees it: the bytes of a
    /// Buffer, typed array or DataView as `stdin`; `maxBufferBytes: Infinity`, which acpx's
    /// check refuses; a `timeoutMs` of `NaN`, which is no deadline; `NaN` as an argument.
    @Test(.enabled(if: nodeAvailable))
    func runShellTakesWhatJSONCannotCarry() async throws {
        let run = try await runnerRun("""
            const attempt = (runShell, execution) =>
              runShell(execution).then((r) => r.stdout, (e) => `${e.name}: ${e.message}`);
            export default defineFlow({ name: "beyond-json", startAt: "a", nodes: {
              a: action({ run: async ({ runShell }) => {
                const bytes = new Uint8Array([0, 118, 105, 101, 119, 0]);
                return [
                  await attempt(runShell, { command: "/bin/cat", stdin: Buffer.from("hi") }),
                  await attempt(runShell, { command: "/bin/cat", stdin: new Uint8Array([111, 107]) }),
                  await attempt(runShell, { command: "/bin/cat", stdin: new DataView(bytes.buffer, 1, 4) }),
                  await attempt(runShell, { command: "/bin/echo", args: ["x"], maxBufferBytes: Infinity }),
                  await attempt(runShell, {
                    command: "/bin/sh", args: ["-c", "sleep 0.2; printf done"], timeoutMs: NaN }),
                  await attempt(runShell, { command: "/bin/echo", args: [NaN, -Infinity] }),
                ];
              } }) },
              edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a")?.stringified == #"["hi","ok","view","#
            + #""Error: Shell action maxBufferBytes must be a non-negative safe integer","done","NaN -Infinity\n"]"#)
    }

    /// acpx hands every callback of an attempt the attempt's own `signal`: a shell action's
    /// `exec` and `parse` share it.
    @Test(.enabled(if: nodeAvailable))
    func anAttemptsCallbacksShareItsSignal() async throws {
        let run = try await runnerRun("""
            let execSignal;
            export default defineFlow({ name: "shared-signal", startAt: "a", nodes: {
              a: shell({
                exec: ({ signal }) => { execSignal = signal; return { command: "/bin/sh", args: ["-c", "true"] }; },
                parse: (result, { signal }) => signal === execSignal }) },
              edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a") == .bool(true))
    }
}
