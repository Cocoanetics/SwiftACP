@testable import ACPXCore
@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// acpx 0.19.3's `FlowRunner` cases (`test/flows.test.ts`), run by the runner itself with
/// the flow's code in the Node host, as `flow run` runs them. Each run keeps its bundle in
/// a directory of its own, so these touch nothing process-wide and need no store isolation
/// (`FlowRunTests` has the cases that go through the CLI).
struct FlowRunnerTests {
    typealias Run = FlowRunnerHarness.Run

    private func runnerRun(
        _ body: String, extension ext: String = "mjs", files: [String: String] = [:],
        input: WireJSON = .object([WireJSON.Member]()), tracking: Bool = false, prelude: Bool = true
    ) async throws -> Run {
        try await FlowRunnerHarness.run(
            body, extension: ext, files: files, input: input, tracking: tracking, prelude: prelude)
    }

    private func member(_ value: WireJSON?, _ path: String...) -> WireJSON? {
        path.reduce(value) { $0?[$1] }
    }

    /// A callback's failure, whatever it throws, and an output `JSON.stringify` cannot
    /// write fail the node and the run, and leave no output (acpx: "records callback and
    /// output serialization failures as failed steps").
    @Test(.enabled(if: nodeAvailable), arguments: [
        ("throw new Error(\"callback failed\")", "callback failed"), ("throw \"plain string\"", "plain string"),
        ("throw undefined", "undefined"), ("throw null", "null"), ("throw false", "false"),
        ("return 1n", "Do not know how to serialize a BigInt")
    ])
    func aFailedCallbackFailsTheRun(_ statement: String, _ message: String) async throws {
        for helper in ["compute", "action", "checkpoint"] {
            let run = try await runnerRun("""
                export default defineFlow({ name: "callback-failure", startAt: "callback",
                  nodes: { callback: \(helper)({ run: () => { \(statement); } }) }, edges: [] });
                """)
            #expect(run.code == 1, "\(helper)")
            #expect(run.err == message, "\(helper)")
            #expect(member(run.state, "status") == .text("failed"))
            // The step is recorded before the run fails, which clears the node it was on.
            #expect(member(run.state, "statusDetail") == .text(message))
            #expect(member(run.state, "results", "callback", "outcome") == .text("failed"))
            #expect(member(run.state, "results", "callback", "error") == .text(message))
            #expect(member(run.state, "results", "callback", "output") == nil)
            #expect(member(run.state, "outputs") == .object([WireJSON.Member]()))
            #expect(run.trace.last?["type"] == .text("run_failed"))
        }
    }

    /// acpx: "can route timed out nodes by outcome".
    @Test(.enabled(if: nodeAvailable))
    func aTimedOutNodeCanRouteOnItsResult() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "timeout-routed", startAt: "slow", nodes: {
              slow: compute({ timeoutMs: 100,
                run: () => new Promise((resolve) => setTimeout(() => resolve(1), 5000)) }),
              recover: compute({ run: ({ results }) => ({ recovered: results.slow.outcome }) }) },
              edges: [{ from: "slow", switch: { on: "$result.outcome", cases: { timed_out: "recover" } } }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "status") == .text("completed"))
        #expect(member(run.state, "outputs", "recover", "recovered") == .text("timed_out"))
        #expect(member(run.state, "outputs", "slow") == nil)
    }

    /// acpx: "preserves failures instead of following direct or output edges".
    @Test(.enabled(if: nodeAvailable), arguments: [#"{ from: "boom", to: "next" }"#,
        #"{ from: "boom", switch: { on: "$.route", cases: { a: "next" } } }"#])
    func aFailureFollowsNoDirectOrOutputEdge(_ edge: String) async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "no-follow", startAt: "boom", nodes: {
              boom: compute({ run: () => { throw new Error("nope"); } }), next: compute({ run: () => "ran" }) },
              edges: [\(edge)] });
            """)
        #expect(run.code == 1)
        #expect(run.err == "nope")
        #expect(member(run.state, "results", "next") == nil)
    }

    /// acpx: "stores successful node results separately from outputs".
    @Test(.enabled(if: nodeAvailable))
    func resultsAreKeptApartFromOutputs() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "results", startAt: "one", nodes: {
              one: compute({ run: () => ({ value: 1 }) }),
              two: compute({ run: ({ results, outputs, state }) => ({ outcome: results.one.outcome,
                output: outputs.one, steps: state.steps.length }) }) },
              edges: [{ from: "one", to: "two" }] });
            """)
        #expect(run.code == 0)
        #expect(member(run.state, "results", "one", "outcome") == .text("ok"))
        #expect(member(run.state, "results", "one", "output", "value") == .number(1))
        #expect(member(run.state, "outputs", "two", "outcome") == .text("ok"))
        #expect(member(run.state, "outputs", "two", "output", "value") == .number(1))
        #expect(member(run.state, "outputs", "two", "steps") == .number(1))
    }

    @Test(.enabled(if: nodeAvailable), arguments: [
        (#"{ route: "x" }"#, #"No flow switch case for $.route="x""#),
        ("{ route: { nested: true } }", "Flow switch value must be scalar for $.route")
    ])
    func aSwitchThatCannotRouteFailsTheRun(_ output: String, _ message: String) async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "switch", startAt: "pick", nodes: {
              pick: compute({ run: () => (\(output)) }), a: compute({ run: () => 1 }) },
              edges: [{ from: "pick", switch: { on: "$.route", cases: { a: "a" } } }] });
            """)
        #expect(run.code == 1)
        #expect(run.err == message)
        #expect(member(run.state, "status") == .text("failed"))
        #expect(member(run.state, "error") == .text(message))
    }

    /// acpx: "flow keys: a standalone __proto__ node publishes own output and result".
    @Test(.enabled(if: nodeAvailable))
    func aProtoNodeIsAnOrdinaryKey() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "proto", startAt: "__proto__",
              nodes: { ["__proto__"]: compute({ run: () => ({ special: true }) }) }, edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "__proto__", "special") == .bool(true))
        #expect(member(run.state, "results", "__proto__", "attemptId") == .text("__proto__#1"))
    }

    /// A `.ts` flow is compiled to CommonJS, as acpx's tsx compiles it: TypeScript's own
    /// syntax, `__dirname`, `require`, and the TypeScript files it imports.
    @Test(.enabled(if: nodeAvailable))
    func aTypeScriptFlowLoadsAsAcpxLoadsIt() async throws {
        let run = try await runnerRun("""
            import { double } from "./helper";
            enum Route { Done = "done" }
            interface Item { name: string }
            const here: string = __dirname;
            const os = require("node:os");
            export default defineFlow({ name: "typed", startAt: "pick", nodes: {
              pick: compute({ run: () => {
                const item: Item = { name: "a" };
                return { route: Route.Done, name: item.name, twice: double(21),
                  hasDir: here.length > 0, platform: typeof os.platform() };
              } }),
              done: compute({ run: () => "done" }) },
              edges: [{ from: "pick", switch: { on: "$.route", cases: { done: "done" } } }] });
            """, extension: "ts",
            files: ["helper.ts": "export function double(value: number): number { return value * 2; }\n"])
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "pick")?.stringified
            == #"{"route":"done","name":"a","twice":42,"hasDir":true,"platform":"string"}"#)
        #expect(member(run.state, "outputs", "done") == .text("done"))
    }

    /// An `.mts` flow is compiled as an ES module, as acpx's tsx compiles it — an `enum`
    /// included, which Node's own type stripping refuses.
    @Test(.enabled(if: nodeAvailable))
    func anMtsFlowLoadsAsAModule() async throws {
        let run = try await runnerRun("""
            enum Kind { Module = "module" }
            const label: string = Kind.Module;
            export default defineFlow({ name: "module", startAt: "a",
              nodes: { a: compute({ run: () => ({ label, meta: typeof import.meta.url }) }) }, edges: [] });
            """, extension: "mts")
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a")?.stringified == #"{"label":"module","meta":"string"}"#)
    }

    /// An `.mts` flow's imports take the formats tsx gives them: a `.cts` helper is
    /// CommonJS, and so is a `.ts` one with no package.json making it a module, whether it
    /// assigns `module.exports` or writes `export` (a Codex finding).
    @Test(.enabled(if: nodeAvailable))
    func anMtsFlowImportsCommonJSHelpersAsTsxDoes() async throws {
        let run = try await runnerRun("""
            import cjs from "./helper.cts";
            import legacy from "./legacy.ts";
            import { quadruple } from "./modern.ts";
            export default defineFlow({ name: "formats", startAt: "a", nodes: {
              a: compute({ run: () => ({ cts: cjs.double(21), ts: legacy.triple(7), esm: quadruple(5) }) }) },
              edges: [] });
            """, extension: "mts", files: [
                "helper.cts": "const double = (n: number): number => n * 2;\nmodule.exports = { double };\n",
                "legacy.ts": "module.exports = { triple: (n: number): number => n * 3 };\n",
                "modern.ts": "export function quadruple(n: number): number { return n * 4; }\n"
            ])
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a")?.stringified == #"{"cts":42,"ts":21,"esm":20}"#)
    }

    /// A TypeScript flow's imports resolve as tsx resolves them, whichever loader takes the
    /// flow: a path with no extension, a `.js` or `.mjs` that is the `.ts` or `.mts` beside
    /// it, and a directory by its index (a Codex finding).
    @Test(.enabled(if: nodeAvailable), arguments: ["mts", "ts"])
    func aTypeScriptFlowsImportsResolveAsTsxResolvesThem(_ ext: String) async throws {
        let run = try await runnerRun("""
            import { one } from "./bare";
            import { two } from "./nodenext.js";
            import { three } from "./lib";
            import { four } from "./mod.mjs";
            export default defineFlow({ name: "resolve", startAt: "a", nodes: {
              a: compute({ run: () => [one(), two(), three(), four()] }) }, edges: [] });
            """, extension: ext, files: [
                "bare.ts": "export const one = (): number => 1;\n",
                "nodenext.ts": "export const two = (): number => 2;\n",
                "lib/index.ts": "export const three = (): number => 3;\n",
                "mod.mts": "export const four = (): number => 4;\n"
            ])
        #expect(run.code == 0, "\(ext): \(run.err)")
        #expect(member(run.state, "outputs", "a")?.stringified == "[1,2,3,4]", "\(ext)")
    }

    /// A `.ts` flow is CommonJS as tsx compiles it, whatever its package's "type", and its
    /// `import.meta` is tsx's: the file's dirname, filename and URL, the URL with the
    /// namespace the flow loads under (a Codex finding).
    @Test(.enabled(if: nodeAvailable), arguments: [false, true])
    func aTypeScriptFlowsImportMetaIsTsxs(_ inModulePackage: Bool) async throws {
        let run = try await runnerRun("""
            const own = require("node:url").pathToFileURL(__filename).href;
            export default defineFlow({ name: "meta", startAt: "a", nodes: {
              a: compute({ run: () => ({ keys: Object.keys(import.meta), dirname: import.meta.dirname === __dirname,
                filename: import.meta.filename === __filename,
                url: import.meta.url.startsWith(own + "?namespace=") }) }) },
              edges: [] });
            """, extension: "ts", files: inModulePackage ? ["package.json": #"{"type":"module"}"#] : [:])
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a")?.stringified
            == #"{"keys":["dirname","filename","url"],"dirname":true,"filename":true,"url":true}"#)
    }

    /// tsx's `import.meta` in a `.ts` flow that starts with a shebang, and holds a name the
    /// swap would otherwise take (Codex findings).
    @Test(.enabled(if: nodeAvailable))
    func aTypeScriptFlowsImportMetaLeavesItsShebangAndNames() async throws {
        let run = try await runnerRun("""
            #!/usr/bin/env node
            import { defineFlow, compute } from "acpx/flows";
            const __acpxImportMeta: string = "mine";
            export default defineFlow({ name: "shebang", startAt: "a", nodes: {
              a: compute({ run: () => ({ mine: __acpxImportMeta, dirname: import.meta.dirname === __dirname }) }) },
              edges: [] });
            """, extension: "ts", prelude: false)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "a")?.stringified == #"{"mine":"mine","dirname":true}"#)
    }

    /// acpx: "requires defineFlow before permission gating".
    @Test(.enabled(if: nodeAvailable))
    func aModuleWithoutDefineFlowIsRefused() async throws {
        let run = try await runnerRun(#"export default { name: "plain", startAt: "a", nodes: {}, edges: [] };"#)
        #expect(run.code == 1)
        #expect(run.err.hasPrefix(#"Flow module must export default defineFlow({...}) from "acpx/flows": "#))
    }

    /// acpx: "resolves and persists dynamic run titles".
    @Test(.enabled(if: nodeAvailable), arguments: [
        (#""  Padded Title  ""#, "Padded Title"), (#"({ input }) => `For ${input.who}`"#, "For you"),
        (#"() => "   ""#, nil)
    ])
    func aRunTitleIsTrimmed(_ title: String, _ expected: String?) async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "titled", run: { title: \(title) }, startAt: "a",
              nodes: { a: compute({ run: () => 1 }) }, edges: [] });
            """, input: try WireJSON.parse(#"{"who":"you"}"#))
        #expect(member(run.state, "runTitle") == expected.map(WireJSON.text))
    }

    /// A callback holding Node's event loop keeps the host from answering anything, its
    /// exit included: the node times out all the same, and the host is killed a second
    /// after it is asked to exit. (acpx runs the callback on its own event loop, which it
    /// holds as well, timers and all: there, nothing ends the run.)
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func aCallbackHoldingTheEventLoopStillTimesOut() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "busy", startAt: "spin",
              nodes: { spin: compute({ timeoutMs: 100, run: () => { while (true) {} } }) }, edges: [] });
            """)
        #expect(run.code == 3)
        #expect(run.err == "Timed out after 100ms")
        #expect(member(run.state, "status") == .text("timed_out"))
        #expect(member(run.state, "results", "spin", "outcome") == .text("timed_out"))
    }

    /// A callback past its deadline that never settles is let go once the runner forgets
    /// its attempt, as nothing holds it in acpx: a flow timing it out again and again
    /// leaves the host holding nothing, nor the runner waiting on it (Codex findings).
    @Test(.enabled(if: nodeAvailable))
    func aTimedOutCallbackThatNeverSettlesIsLetGo() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "stall-again", startAt: "stall", nodes: {
              stall: compute({ timeoutMs: 50, run: () => new Promise(() => {}) }),
              count: compute({ run: ({ outputs }) => ({ n: (outputs.count?.n ?? 0) + 1 }) }),
              done: compute({ run: () => "done" }) },
              edges: [
                { from: "stall", switch: { on: "$result.outcome", cases: { timed_out: "count" } } },
                { from: "count", switch: { on: "$.n", cases: { 1: "stall", 2: "stall", 3: "done" } } }] });
            """, tracking: true)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "done") == .text("done"))
        #expect(member(run.state, "results", "stall", "attemptId") == .text("stall#3"))
        #expect(run.tracked?.stringified == #"{"running":0,"returned":0}"#)
        #expect(run.pendingRequests == 0)
    }

    /// A host that exits of its own accord after its last answer — a timer's
    /// `process.exit(7)` — is told apart from one that exits when asked: `flow run` ends
    /// with its code, as acpx's own process ends then (a Codex finding).
    @Test(.enabled(if: nodeAvailable))
    func aHostThatExitsAfterItsLastAnswerIsToldApart() async throws {
        let node = try #require(AgentRegistry.which("node"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, run) in [("late", "setTimeout(() => process.exit(7), 0); return 1;"), ("plain", "return 1;")] {
            let flowFile = dir.appendingPathComponent("\(name).flow.mjs")
            try """
                import { defineFlow, compute } from "acpx/flows";
                export default defineFlow({ name: "\(name)", startAt: "a",
                  nodes: { a: compute({ run: () => { \(run) } }) }, edges: [] });
                """.write(to: flowFile, atomically: true, encoding: .utf8)
            let host = try FlowHost.start(node: node, cwd: dir.path, environment: ProcessInfo.processInfo.environment)
            let loaded = try await host.request("flow/load", .object([WireJSON.Member("path", .text(flowFile.path))]))
            let options = FlowRunner.Options(outputRoot: dir.appendingPathComponent("runs"), defaultCwd: dir.path)
            let runner = FlowRunner(host: host, options: options)
            _ = try await runner.run(FlowDescription(loaded: loaded ?? .null), input: .null, flowPath: flowFile.path)
            if name == "late" { _ = await host.exitStatus() }
            let status = await host.stop()
            #expect(host.exitedOnItsOwn == (name == "late"), "\(name)")
            #expect(FlowHost.exitCode(waitStatus: status) == (name == "late" ? 7 : 0), "\(name)")
        }
    }

    /// Node ids that are array indices come first in `outputs` and `results`, in numeric
    /// order, as a JavaScript object lists them whatever order they were set in.
    @Test(.enabled(if: nodeAvailable))
    func numericNodeIdsAreListedAsJavaScriptListsThem() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "numeric", startAt: "2", nodes: {
              b: compute({ run: () => "b" }), 2: compute({ run: () => 2 }), 10: compute({ run: () => 10 }),
              1: compute({ run: () => 1 }), "01": compute({ run: () => "01" }) },
              edges: [{ from: "2", to: "b" }, { from: "b", to: "10" }, { from: "10", to: "01" },
                { from: "01", to: "1" }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        for container in ["outputs", "results"] {
            let keys = member(run.state, container)?.objectMembers.map { String(decoding: $0.key, as: UTF16.self) }
            #expect(keys == ["1", "2", "10", "b", "01"], "\(container)")
        }
    }

    /// A node that runs sends a heartbeat every `heartbeatMs`: this one runs until the
    /// runner has written two, however slowly the disk takes them — or, with none, until
    /// its deadline fails the run.
    @Test(.enabled(if: nodeAvailable))
    func aRunningNodeSendsHeartbeats() async throws {
        let run = try await runnerRun("""
            import fs from "node:fs";
            import path from "node:path";
            import { fileURLToPath } from "node:url";
            const runs = path.join(path.dirname(fileURLToPath(import.meta.url)), "runs");
            function heartbeats(runId) {
              try {
                const trace = fs.readFileSync(path.join(runs, runId, "trace.ndjson"), "utf8");
                return trace.split("\\n").filter((line) => line.includes('"type":"node_heartbeat"')).length;
              } catch {
                return 0;
              }
            }
            export default defineFlow({ name: "heartbeat", startAt: "slow", nodes: {
              slow: compute({ heartbeatMs: 50, timeoutMs: 10000, statusDetail: "Working",
                run: ({ state }) => new Promise((resolve) => {
                const check = () => (heartbeats(state.runId) >= 2 ? resolve(1) : setTimeout(check, 10));
                check();
              }) }) },
              edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        let heartbeats = run.trace.filter { $0["type"] == .text("node_heartbeat") }
        #expect(heartbeats.count >= 2)
        #expect(heartbeats.allSatisfy { $0["payload"]?["statusDetail"] == .text("Working") })
    }
}
