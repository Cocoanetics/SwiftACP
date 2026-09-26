@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// The flow's own JavaScript values in a shell command's spec, which acpx's runner holds as
/// they are and SwiftACP's host sends the runner as JSON: each run by the runner with the
/// flow's code in the Node host, and each matching what acpx 0.19.3 does with the value.
struct FlowShellSpecTests {
    private func runnerRun(_ body: String) async throws -> FlowRunnerHarness.Run {
        try await FlowRunnerHarness.run(body)
    }

    private func member(_ value: WireJSON?, _ path: String...) -> WireJSON? {
        path.reduce(value) { $0?[$1] }
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

    /// An object of a class as one of the spec's own members — a URL for `cwd` — is refused
    /// by its class, as Node refuses it, though JSON would write it as a string (`toJSON`).
    @Test(.enabled(if: nodeAvailable))
    func aClassInstanceIsRefusedByItsClass() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "instance", startAt: "a", nodes: {
              a: shell({ exec: () => ({ command: "/bin/pwd", cwd: new URL("file:///tmp") }) }) }, edges: [] });
            """)
        #expect(run.code == 1)
        #expect(run.err == #"The "paths[1]" argument must be of type string. Received an instance of URL"#)
    }

    /// Node checks for a NUL only in what was a string; a value converted to one with a NUL
    /// ends at it, as a C string does — with `shell`, the whole command. And a value JSON
    /// would write as a string is refused by its type, as Node names it.
    @Test(.enabled(if: nodeAvailable))
    func runShellTruncatesAndNamesAsNodeDoes() async throws {
        let run = try await runnerRun("""
            const nul = { toString: () => "b\\0c" };
            const attempt = (runShell, execution) =>
              runShell(execution).then((r) => r.stdout, (e) => `${e.code}: ${e.message}`);
            export default defineFlow({ name: "node-rules", startAt: "a", nodes: {
              a: action({ run: async ({ runShell }) => [
                await attempt(runShell, { command: "/bin/echo", args: ["a", nul, "d"] }),
                await attempt(runShell, { command: "echo", args: ["a", nul, "d"], shell: true }),
                await attempt(runShell, { command: "/bin/sh", args: ["-c", 'printf "[%s]" "$X"'],
                  env: { X: { toString: () => "p\\0q" } } }),
                await attempt(runShell, { command: { toJSON: () => "/bin/echo" }, args: ["x"] }),
                await attempt(runShell, { command: function named() {}, args: ["x"] }),
              ] }) },
              edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        let refused = #"ERR_INVALID_ARG_TYPE: The "file" argument must be of type string. Received "#
        #expect(member(run.state, "outputs", "a") == .array([
            .text("a b d\n"), .text("a b\n"), .text("[p]"),
            .text(refused + "an instance of Object"), .text(refused + "function named")
        ]))
    }

    /// The spec read as acpx reads it: its own members, as `{ ...execution }` copies them,
    /// and off the spec itself `cwd` — and for a shell action `timeoutMs` — prototype and
    /// all; a list's holes as `undefined`; `args` that are an object as Node's options; and
    /// the flow's own objects as they are, whatever their keys.
    @Test(.enabled(if: nodeAvailable))
    func theSpecIsReadAsAcpxReadsIt() async throws {
        let run = try await runnerRun("""
            const attempt = (runShell, execution) =>
              runShell(execution).then((r) => [r.stdout, r.cwd], (e) => `${e.name}: ${e.message}`);
            const on = (prototype, own) => Object.assign(Object.create(prototype), own);
            export default defineFlow({ name: "spec-shapes", startAt: "a", nodes: {
              a: action({ run: async ({ runShell }) => [
                await attempt(runShell, on({ command: "/bin/echo" }, { args: ["ok"] })),
                await attempt(runShell, on({ cwd: "/tmp" }, { command: "/bin/pwd" })),
                await attempt(runShell, on({ timeoutMs: 100 },
                  { command: "/bin/sh", args: ["-c", "sleep 0.5; printf done"] })),
                await attempt(runShell, { command: "/bin/echo", args: Array(1) }),
                await attempt(runShell, { command: "echo", args: ["a", , "b"], shell: true }),
                await attempt(runShell, { command: "/bin/pwd", args: { cwd: "/usr" }, cwd: "/" }),
                await attempt(runShell, { command: "/bin/echo", args: [{ "\\0acpx": "bigint", text: "1" }] }),
              ] }),
              c: shell({ exec: () => ({ command: "/bin/echo", args: [{ "\\0acpx": "bigint", text: "1" }] }),
                parse: (r) => r.stdout }),
              b: shell({ exec: () => on({ cwd: "/tmp", timeoutMs: 100 },
                { command: "/bin/sh", args: ["-c", "sleep 0.5"] }) }) },
              edges: [{ from: "a", to: "c" }, { from: "c", to: "b" }] });
            """)
        #expect(run.code == 3)
        #expect(member(run.state, "results", "b", "outcome") == .text("timed_out"))
        // A flow's object whose key looks like the runner's marker is shown and traced as it is.
        #expect(member(run.state, "outputs", "c") == .text("[object Object]\n"))
        let traced = run.trace.first { $0["type"] == .text("action_prepared") && $0["nodeId"] == .text("c") }
        #expect(traced?["payload"]?["action"]?["args"] == .array([.object([
            ("\u{0}acpx", .text("bigint")), ("text", .text("1"))
        ])]))
        // The runner's own working directory, where the commands without one ran.
        guard case .array(let results)? = member(run.state, "outputs", "a"), results.count == 7,
              case .array(let timed) = results[2], timed.count == 2 else {
            Issue.record("\(String(describing: member(run.state, "outputs", "a")))")
            return
        }
        let dir = timed[1]
        #expect(member(run.state, "outputs", "a") == .array([
            .text(#"TypeError: The "file" argument must be of type string. Received undefined"#),
            .array([.text("/private/tmp\n"), .text("/tmp")]), .array([.text("done"), dir]),
            .array([.text("undefined\n"), dir]), .array([.text("a b\n"), dir]),
            .array([.text("/usr\n"), .text("/")]), .array([.text("[object Object]\n"), dir])
        ]))
    }

    /// acpx spreads `env` into the command's environment (`{ ...process.env, ...spec.env }`):
    /// an object's own members, a string's characters and a list's items by index, nothing
    /// of a number.
    @Test(.enabled(if: nodeAvailable))
    func envIsSpreadAsAcpxSpreadsIt() async throws {
        let run = try await runnerRun("""
            const variables = (runShell, env) => runShell({ command: "/bin/sh", env,
              args: ["-c", 'env | grep -E "^(0|1|X)=" | sort | tr "\\n" ";"'] }).then((r) => r.stdout);
            export default defineFlow({ name: "env-spread", startAt: "a", nodes: {
              a: action({ run: async ({ runShell }) => [
                await variables(runShell, "ab"), await variables(runShell, ["p", "q"]), await variables(runShell, 5),
                await variables(runShell, Object.assign(Object.create({ X: "inherited" }), { 1: "own" })),
              ] }) },
              edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a") == .array([
            .text("0=a;1=b;"), .text("0=p;1=q;"), .text(""), .text("1=own;")
        ]))
    }

    /// Node's options, when `args` is an object, as Node reads them: each value with its
    /// type, a file URL as its path, a Buffer `cwd` let through and then ignored; and what is
    /// left of a spec: an inherited `args` gone with the spread, a `timeoutMs` object by its
    /// number. The environment comes in Node's order: this process's variables, then the
    /// spec's new ones in its order.
    @Test(.enabled(if: nodeAvailable))
    func optionsAndTheEnvironmentAreNodes() async throws {
        let run = try await runnerRun("""
            const attempt = (runShell, execution) =>
              runShell(execution).then((r) => [r.stdout, r.timedOut], (e) => `${e.code}: ${e.message}`);
            export default defineFlow({ name: "node-options", startAt: "a", nodes: {
              a: action({ run: async ({ runShell }) => {
                const env = await runShell({ command: "/usr/bin/env", env: { Z: "1", A: "2" } });
                return [
                  await attempt(runShell, Object.assign(Object.create({ args: ["no"] }), { command: "/bin/echo" })),
                  await attempt(runShell, { command: "echo", args: { shell: new Boolean(true) } }),
                  await attempt(runShell, { command: "/bin/pwd", args: { cwd: new URL("file:///usr") } }),
                  await attempt(runShell, { command: "/bin/pwd", args: { cwd: new URL("https://example.com/") } }),
                  await attempt(runShell, { command: "/bin/sh", args: ["-c", "sleep 1"], timeoutMs: new Number(100) }),
                  env.stdout.trim().split("\\n").map((line) => line.split("=")[0]).slice(-2).join(","),
                ];
              } }) },
              edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a") == .array([
            .array([.text("\n"), .bool(false)]),
            .text(#"ERR_INVALID_ARG_TYPE: The "options.shell" property must be one of type boolean or string. "#
                + "Received an instance of Boolean"),
            .array([.text("/usr\n"), .bool(false)]),
            .text("ERR_INVALID_URL_SCHEME: The URL must be of scheme file"),
            .array([.text(""), .bool(true)]),
            .text("Z,A")
        ]))
    }
}
