@testable import ACPXCore
@testable import ACPXFlows
@testable import acpx
import Foundation
import SwiftACP
import Testing

let nodeAvailable = AgentRegistry.which("node") != nil

/// `flow run` as acpx 0.19.3 runs a flow of compute, function action and checkpoint
/// nodes (#202): the flow's code in the Node host, the walk, the deadlines and the run
/// bundle in Swift. Most of these are acpx's own `FlowRunner` and `flow run` tests
/// (`test/flows.test.ts`, `test/integration.test.ts`); `theBundleIsWrittenAsAcpxWritesIt`
/// compares a whole bundle with one acpx wrote.
@Suite(.serialized) struct FlowRunTests {
    struct Run {
        var out: String
        var err: String
        var code: Int32
        /// The run's projection and trace, when the run got that far.
        var state: WireJSON?
        var trace: [WireJSON] = []
        var runDir: URL?
        /// The bundle's files, normalized as the golden fixture is (a file run only).
        var goldenFiles: [String: [String: String]] = [:]
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/flows")

    /// `flow run` on a flow module: `body` after acpx's helpers are imported, or the file
    /// `file` names. `options` go before `flow run`, `arguments` after the file. With
    /// `interrupting`, a signal arrives once the flow writes to the file `$READY` names.
    private func flowRun(
        _ body: String? = nil, file: URL? = nil, options: [String] = [], arguments: [String] = [],
        interrupting: Bool = false
    ) async throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready")
        var flowFile = dir.appendingPathComponent("test.flow.mjs")
        if let body {
            let source = "import { defineFlow, action, checkpoint, compute } from \"acpx/flows\";\n"
                + "import fs from \"node:fs\";\nconst READY = \(ready.path.debugDescription);\n" + body
            try source.write(to: flowFile, atomically: true, encoding: .utf8)
        } else if let file {
            flowFile = dir.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: flowFile)
        }
        let source = Interrupts.Source()
        let watch = interrupting ? try ExecInterruptTests.fire(source, whenWrittenTo: ready) : nil
        defer { watch?.cancel() }
        let args = ["--cwd", dir.path] + options + ["flow", "run", flowFile.path] + arguments
        return await withIsolatedStore {
            let capture = Console.Capture()
            // `flow run` blocks its thread until it is done, as the CLI does: a thread of its own.
            let code: Int32 = await withCheckedContinuation { continuation in
                Thread {
                    let code = Console.$capture.withValue(capture) {
                        Interrupts.$source.withValue(interrupting ? source : nil) { runCommandLine(args) }
                    }
                    continuation.resume(returning: code)
                }.start()
            }
            var run = Run(out: capture.out, err: capture.err, code: code)
            let runs = FlowRunner.runsBaseDir()
            if let name = try? FileManager.default.contentsOfDirectory(atPath: runs.path).first {
                let runDir = runs.appendingPathComponent(name)
                run.runDir = runDir
                run.state = try? WireJSON.parse(String(
                    contentsOf: runDir.appendingPathComponent("projections/run.json"), encoding: .utf8))
                let traceFile = runDir.appendingPathComponent("trace.ndjson")
                let trace = (try? String(contentsOf: traceFile, encoding: .utf8)) ?? ""
                run.trace = trace.split(separator: "\n").compactMap { try? WireJSON.parse(String($0)) }
                if body == nil { run.out = Self.normalized(run.out, runs: runs, flowDir: dir, runId: name) }
                if body == nil { run.goldenFiles = Self.files(in: runDir, runs: runs, flowDir: dir, runId: name) }
            }
            return run
        }
    }

    /// acpx's golden bundle's placeholders, for a run of it here.
    static func normalized(_ text: String, runs: URL, flowDir: URL, runId: String) -> String {
        var text = text.replacingOccurrences(of: runId, with: "<RUNID>")
            .replacingOccurrences(of: runs.path, with: "<RUNS>")
            .replacingOccurrences(of: flowDir.path, with: "<FLOWDIR>")
        text = text.replacingOccurrences(
            of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"#, with: "<TIME>", options: .regularExpression)
        return text.replacingOccurrences(
            of: #""durationMs":( ?)\d+"#, with: #""durationMs":$1<MS>"#, options: .regularExpression)
    }

    static func files(in runDir: URL, runs: URL, flowDir: URL, runId: String) -> [String: [String: String]] {
        var files: [String: [String: String]] = [:]
        let enumerator = FileManager.default.enumerator(atPath: runDir.path)
        while let relative = enumerator?.nextObject() as? String {
            let url = runDir.appendingPathComponent(relative)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let mode = attributes[.posixPermissions] as? Int,
                  let content = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            files[relative] = [
                "mode": "0o" + String(mode & 0o777, radix: 8),
                "content": normalized(content, runs: runs, flowDir: flowDir, runId: runId)
            ]
        }
        return files
    }

    private func member(_ value: WireJSON?, _ path: String...) -> WireJSON? {
        path.reduce(value) { $0?[$1] }
    }

    // MARK: - A bundle as acpx writes it

    @Test(.enabled(if: nodeAvailable))
    func theBundleIsWrittenAsAcpxWritesIt() async throws {
        let fixture = try WireJSON.parse(String(
            contentsOf: Self.fixtures.appendingPathComponent("golden-acpx-0.19.3.json"), encoding: .utf8))
        let run = try await flowRun(
            file: Self.fixtures.appendingPathComponent("golden.flow.mjs"), options: ["--format", "json"],
            arguments: ["--input-json", #"{"label":"batch"}"#])
        #expect(run.code == 0, "\(run.err)")
        #expect(run.out == fixture["stdout"]?.stringValue)
        let expected = fixture["files"]?.objectMembers ?? []
        #expect(Set(run.goldenFiles.keys) == Set(expected.map { String(decoding: $0.key, as: UTF16.self) }))
        for file in expected {
            let path = String(decoding: file.key, as: UTF16.self)
            #expect(run.goldenFiles[path]?["content"] == file.value["content"]?.stringValue, "\(path)")
            #expect(run.goldenFiles[path]?["mode"] == file.value["mode"]?.stringValue, "\(path)")
        }
    }

    // MARK: - How a run ends

    @Test(.enabled(if: nodeAvailable))
    func aCheckpointLeavesTheRunWaiting() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "wait", startAt: "prep", nodes: {
              prep: compute({ run: () => ({ ok: true }) }), hold: checkpoint({ summary: "review needed" }) },
              edges: [{ from: "prep", to: "hold" }] });
            """)
        #expect(run.code == 0)
        let lines = run.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first?.hasPrefix("runId: ") == true)
        #expect(lines.contains("flow: wait") && lines.contains("status: waiting"))
        #expect(lines.contains("statusDetail: review needed") && lines.contains("waitingOn: hold"))
        #expect(member(run.state, "outputs", "hold") == .object([
            WireJSON.Member("checkpoint", .text("hold")), WireJSON.Member("summary", .text("review needed"))
        ]))
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
            let run = try await flowRun("""
                export default defineFlow({ name: "callback-failure", startAt: "callback",
                  nodes: { callback: \(helper)({ run: () => { \(statement); } }) }, edges: [] });
                """)
            #expect(run.code == 1, "\(helper)")
            #expect(run.err == message + "\n", "\(helper)")
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

    @Test(.enabled(if: nodeAvailable))
    func aNodePastItsDeadlineTimesOut() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "timeout", startAt: "slow", nodes: {
              slow: compute({ timeoutMs: 100,
                run: () => new Promise((resolve) => setTimeout(() => resolve(1), 5000)) }) },
              edges: [] });
            """)
        #expect(run.code == 3)
        #expect(run.err.hasPrefix("Timed out after 100ms\nhint: increase `--timeout <seconds>`"))
        #expect(member(run.state, "status") == .text("timed_out"))
        #expect(member(run.state, "results", "slow", "outcome") == .text("timed_out"))
    }

    /// acpx: "can route timed out nodes by outcome".
    @Test(.enabled(if: nodeAvailable))
    func aTimedOutNodeCanRouteOnItsResult() async throws {
        let run = try await flowRun("""
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
        let run = try await flowRun("""
            export default defineFlow({ name: "no-follow", startAt: "boom", nodes: {
              boom: compute({ run: () => { throw new Error("nope"); } }), next: compute({ run: () => "ran" }) },
              edges: [\(edge)] });
            """)
        #expect(run.code == 1)
        #expect(run.err == "nope\n")
        #expect(member(run.state, "results", "next") == nil)
    }

    /// acpx: "stores successful node results separately from outputs".
    @Test(.enabled(if: nodeAvailable))
    func resultsAreKeptApartFromOutputs() async throws {
        let run = try await flowRun("""
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
        let run = try await flowRun("""
            export default defineFlow({ name: "switch", startAt: "pick", nodes: {
              pick: compute({ run: () => (\(output)) }), a: compute({ run: () => 1 }) },
              edges: [{ from: "pick", switch: { on: "$.route", cases: { a: "a" } } }] });
            """)
        #expect(run.code == 1)
        #expect(run.err == message + "\n")
        #expect(member(run.state, "status") == .text("failed"))
        #expect(member(run.state, "error") == .text(message))
    }

    /// acpx: "flow keys: a standalone __proto__ node publishes own output and result".
    @Test(.enabled(if: nodeAvailable))
    func aProtoNodeIsAnOrdinaryKey() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "proto", startAt: "__proto__",
              nodes: { ["__proto__"]: compute({ run: () => ({ special: true }) }) }, edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs", "__proto__", "special") == .bool(true))
        #expect(member(run.state, "results", "__proto__", "attemptId") == .text("__proto__#1"))
    }

    // MARK: - Before the run

    @Test(.enabled(if: nodeAvailable))
    func aFlowNeedingAPermissionModeIsRefusedBelowIt() async throws {
        let body = """
            export default defineFlow({ name: "needs-all", startAt: "a",
              permissions: { requiredMode: "approve-all", requireExplicitGrant: true, reason: "It writes files" },
              nodes: { a: compute({ run: () => 1 }) }, edges: [] });
            """
        let refused = try await flowRun(body)
        #expect(refused.code == 2)
        #expect(refused.err == """
            Flow "needs-all" requires an explicit approve-all grant. Rerun with --approve-all. Reason: It writes files

            """)
        #expect(refused.state == nil)
        let low = try await flowRun(body, options: ["--approve-reads"])
        #expect(low.err == """
            Flow "needs-all" requires permission mode approve-all. Rerun with --approve-all. Reason: It writes files

            """)
        let granted = try await flowRun(body, options: ["--approve-all"])
        #expect(granted.code == 0)
    }

    /// acpx: "requires defineFlow before permission gating".
    @Test(.enabled(if: nodeAvailable))
    func aModuleWithoutDefineFlowIsRefused() async throws {
        let run = try await flowRun(#"export default { name: "plain", startAt: "a", nodes: {}, edges: [] };"#)
        #expect(run.code == 1)
        #expect(run.err.hasPrefix(#"Flow module must export default defineFlow({...}) from "acpx/flows": "#))
    }

    @Test(.enabled(if: nodeAvailable))
    func theInputComesFromAFlagOrAFile() async throws {
        let body = """
            export default defineFlow({ name: "input", startAt: "echo",
              nodes: { echo: compute({ run: ({ input }) => input }) }, edges: [] });
            """
        let json = try await flowRun(body, arguments: ["--input-json", #"{"b": 1, "a": [true]}"#])
        #expect(member(json.state, "outputs", "echo")?.stringified == #"{"b":1,"a":[true]}"#)
        let bad = try await flowRun(body, arguments: ["--input-json", "{nope"])
        #expect(bad.code == 2)
        #expect(bad.err.hasPrefix("--input-json must contain valid JSON: "))
        let both = try await flowRun(body, arguments: ["--input-json", "{}", "--input-file", "x.json"])
        #expect(both.err == "Use only one of --input-json or --input-file\n")
    }

    /// acpx: "resolves and persists dynamic run titles".
    @Test(.enabled(if: nodeAvailable), arguments: [
        (#""  Padded Title  ""#, "Padded Title"), (#"({ input }) => `For ${input.who}`"#, "For you"),
        (#"() => "   ""#, nil)
    ])
    func aRunTitleIsTrimmed(_ title: String, _ expected: String?) async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "titled", run: { title: \(title) }, startAt: "a",
              nodes: { a: compute({ run: () => 1 }) }, edges: [] });
            """, arguments: ["--input-json", #"{"who":"you"}"#])
        #expect(member(run.state, "runTitle") == expected.map(WireJSON.text))
    }

    // MARK: - While a node runs

    /// acpx: "flow run finalizes interrupted bundles on SIGHUP".
    @Test(.enabled(if: nodeAvailable))
    func anInterruptedRunIsRecordedAsFailed() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "fixture-interrupt", startAt: "slow", nodes: {
              slow: compute({ run: () => new Promise(() => { fs.writeFileSync(READY, "x"); }) }) }, edges: [] });
            """, options: ["--format", "json"], interrupting: true)
        #expect(run.code == 130)
        #expect(run.out.isEmpty && run.err.isEmpty)
        #expect(member(run.state, "status") == .text("failed"))
        #expect(member(run.state, "error") == .text("Interrupted"))
        #expect(member(run.state, "currentNode") == .text("slow"))
        #expect(member(run.state, "currentAttemptId") == .text("slow#1"))
        #expect(member(run.state, "statusDetail") == .text("Failed in slow: Interrupted"))
        #expect(run.trace.last?["type"] == .text("run_failed"))
        #expect(run.trace.last?["payload"]?["error"] == .text("Interrupted"))
    }

    @Test(.enabled(if: nodeAvailable))
    func aRunningNodeSendsHeartbeats() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "heartbeat", startAt: "slow", nodes: {
              slow: compute({ heartbeatMs: 50, statusDetail: "Working",
                run: () => new Promise((resolve) => setTimeout(() => resolve(1), 400)) }) },
              edges: [] });
            """)
        #expect(run.code == 0)
        let heartbeats = run.trace.filter { $0["type"] == .text("node_heartbeat") }
        #expect(heartbeats.count >= 2)
        #expect(heartbeats.allSatisfy { $0["payload"]?["statusDetail"] == .text("Working") })
    }
}
