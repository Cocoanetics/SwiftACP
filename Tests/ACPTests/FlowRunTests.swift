@testable import ACPXCore
@testable import ACPXFlows
@testable import acpx
import Foundation
import SwiftACP
import Testing

let nodeAvailable = AgentRegistry.which("node") != nil

/// `flow run` as acpx 0.19.3 runs a flow of compute, function action and checkpoint
/// nodes (#202): the flow's code in the Node host, the walk, the deadlines and the run
/// bundle in Swift. These go through the CLI, under the process-wide store isolation;
/// they are acpx's own `flow run` tests (`test/flows.test.ts`,
/// `test/integration.test.ts`), and `theBundleIsWrittenAsAcpxWritesIt` compares a whole
/// bundle with one acpx wrote. `FlowRunnerTests` has the cases the runner alone decides.
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
    /// `interrupting`, `signal` arrives once the flow writes to the file `$READY` names.
    private func flowRun(
        _ body: String? = nil, file: URL? = nil, options: [String] = [], arguments: [String] = [],
        interrupting: Bool = false, signal: String = "SIGINT", extension ext: String = "mjs",
        files: [String: String] = [:]
    ) async throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready")
        var flowFile = dir.appendingPathComponent("test.flow.\(ext)")
        for (name, content) in files {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        if let body {
            let source = "import { defineFlow, action, checkpoint, compute, shell } from \"acpx/flows\";\n"
                + "import fs from \"node:fs\";\nconst READY = \(ready.path.debugDescription);\n" + body
            try source.write(to: flowFile, atomically: true, encoding: .utf8)
        } else if let file {
            flowFile = dir.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: flowFile)
        }
        let source = Interrupts.Source()
        let watch = interrupting ? try ExecInterruptTests.fire(source, whenWrittenTo: ready, signal: signal) : nil
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

    /// A flow's own `process.exit()` ends acpx in acpx, whose process runs the flow: with
    /// that code, nothing printed, and the bundle as it was — the node still running.
    @Test(.enabled(if: nodeAvailable))
    func aFlowThatExitsEndsTheRunAsItIs() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "exit", startAt: "a",
              nodes: { a: compute({ run: () => { process.exit(7); } }) }, edges: [] });
            """)
        #expect(run.code == 7)
        #expect(run.out.isEmpty && run.err.isEmpty)
        #expect(member(run.state, "status") == .text("running"))
        #expect(member(run.state, "currentNode") == .text("a"))
        #expect(run.trace.last?["type"] == .text("node_started"))
    }

    /// A run that ends leaves the flow's own timers to run out, as acpx's process does:
    /// the result is printed, and a timer's `process.exit(7)` then ends it with 7 — only a
    /// failure makes acpx exit at once.
    @Test(.enabled(if: nodeAvailable))
    func aRunLeavesTheFlowsTimersToRunOut() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "late", startAt: "a",
              nodes: { a: compute({ run: () => { setTimeout(() => process.exit(7), 1000); return 1; } }) },
              edges: [] });
            """)
        #expect(run.code == 7)
        #expect(run.out.hasPrefix("runId: ") && run.out.contains("status: completed"), "\(run.out)")
        #expect(member(run.state, "status") == .text("completed"))
        let failed = try await flowRun("""
            export default defineFlow({ name: "late-failure", startAt: "a", nodes: {
              a: compute({ run: () => { setTimeout(() => process.exit(7), 1000); throw new Error("nope"); } }) },
              edges: [] });
            """)
        #expect(failed.code == 1)
        #expect(failed.err == "nope\n")
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

    // MARK: - While a node runs

    /// acpx: "flow run finalizes interrupted bundles on SIGHUP".
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func anInterruptedRunIsRecordedAsFailed() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "fixture-interrupt", startAt: "slow", nodes: {
              slow: compute({ run: () => new Promise(() => { fs.writeFileSync(READY, "x"); }) }) }, edges: [] });
            """, options: ["--format", "json"], interrupting: true, signal: "SIGHUP")
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

    /// Interrupted while a callback holds Node's event loop, the run ends all the same: the
    /// host, which cannot answer, is killed.
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func anInterruptEndsARunWhoseCallbackHoldsTheEventLoop() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "busy-interrupt", startAt: "spin", nodes: {
              spin: compute({ run: () => { fs.writeFileSync(READY, "x"); while (true) {} } }) }, edges: [] });
            """, interrupting: true)
        #expect(run.code == 130)
        #expect(member(run.state, "status") == .text("failed"))
        #expect(member(run.state, "error") == .text("Interrupted"))
    }

    /// A file for a test's command to write to, as a JavaScript string literal, and what it
    /// holds.
    private func scratch(_ name: String) -> (path: URL, js: String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString)-\(name)")
        return (path, WireJSON.text(path.path).stringified)
    }

    private func contents(_ path: URL) -> String? {
        defer { try? FileManager.default.removeItem(at: path) }
        return try? String(contentsOf: path, encoding: .utf8)
    }

    /// acpx: "POSIX flow interruption forwards SIGINT and waits for shell cleanup" and "one
    /// foreground Ctrl-C delivers one graceful interrupt to the shell": the command, in a
    /// session of its own, hears the signal once — the one the run heard (acpx's
    /// `withInterrupt` hands it on) — and the run waits for it to finish.
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)), arguments: ["SIGINT", "SIGTERM", "SIGHUP"])
    func anInterruptForwardsItsSignalToTheShellCommandOnce(_ signal: String) async throws {
        let marker = scratch("count")
        let run = try await flowRun("""
            const script = "let count=0;process.on('\(signal)',()=>{if(++count>1)process.exit(2);setTimeout(()=>{"
              + "require('node:fs').writeFileSync(" + JSON.stringify(\(marker.js))
              + ",String(count));process.exit(0)},200)});"
              + "for(const s of ['SIGINT','SIGTERM','SIGHUP'])if(s!=='\(signal)')process.on(s,()=>{});"
              + "require('node:fs').writeFileSync(" + JSON.stringify(READY) + ",'x');setInterval(()=>{},1000)";
            export default defineFlow({ name: "one-interrupt", startAt: "work", nodes: {
              work: shell({ timeoutMs: 0,
                exec: () => ({ command: process.execPath, args: ["-e", script], timeoutMs: 0 }) }) },
              edges: [] });
            """, interrupting: true, signal: signal)
        #expect(run.code == 130)
        #expect(contents(marker.path) == "1")
        #expect(member(run.state, "error") == .text("Interrupted"))
    }

    /// acpx: "foreground interruption reaches descendants after normal shell completion": a
    /// command's child left running after it exited is still the run's to interrupt.
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func anInterruptReachesWhatAFinishedShellActionLeft() async throws {
        let marker = scratch("signal")
        let run = try await flowRun("""
            const child = "process.on('SIGINT',()=>{require('node:fs').writeFileSync(" + JSON.stringify(\(marker.js))
              + ",'SIGINT');process.exit(0)});process.stdout.write('ready');setInterval(()=>{},1000)";
            // The wrapper goes once its child is ready.
            const wrapper = "const c=require('node:child_process').spawn(process.execPath,['-e',"
              + JSON.stringify(child) + "],{stdio:['ignore','pipe','ignore']});"
              + "c.stdout.once('data',()=>process.exit(0))";
            export default defineFlow({ name: "background-signal", startAt: "launch", nodes: {
              launch: shell({ timeoutMs: 0,
                exec: () => ({ command: process.execPath, args: ["-e", wrapper], timeoutMs: 0 }) }),
              waiting: compute({ timeoutMs: 0, run: () => new Promise(() => { fs.writeFileSync(READY, "x"); }) }) },
              edges: [{ from: "launch", to: "waiting" }] });
            """, interrupting: true)
        #expect(run.code == 130)
        #expect(member(run.state, "results", "launch", "outcome") == .text("ok"))
        #expect(contents(marker.path) == "SIGINT")
    }

    /// acpx: "foreground Ctrl-C retains detached descendants when the wrapper exits on
    /// SIGINT": a descendant in a session of its own, deaf to the signal, is killed once its
    /// grace is up.
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func anInterruptStopsADetachedDescendantItsWrapperLeft() async throws {
        let (marker, pidFile) = (scratch("wrapper-signal"), scratch("pid"))
        let run = try await flowRun("""
            const descendant = "process.on('SIGINT',()=>{});process.on('SIGTERM',()=>{});"
              + "require('node:fs').writeFileSync(" + JSON.stringify(\(pidFile.js)) + ",String(process.pid));"
              + "require('node:fs').writeFileSync(" + JSON.stringify(READY) + ",'x');setInterval(()=>{},1000)";
            const wrapper = "process.on('SIGINT',()=>{require('node:fs').writeFileSync(" + JSON.stringify(\(marker.js))
              + ",'SIGINT');process.exit(0)});require('node:child_process').spawn(process.execPath,['-e',"
              + JSON.stringify(descendant) + "],{stdio:'ignore',detached:true});setInterval(()=>{},1000)";
            export default defineFlow({ name: "wrapper-race", startAt: "work", nodes: {
              work: shell({ timeoutMs: 0,
                exec: () => ({ command: process.execPath, args: ["-e", wrapper], timeoutMs: 0 }) }) },
              edges: [] });
            """, interrupting: true)
        #expect(run.code == 130)
        #expect(contents(marker.path) == "SIGINT")
        let pid = try #require(pid_t(contents(pidFile.path) ?? ""))
        #expect(kill(pid, 0) != 0 || ProcessTable.snapshot()?[pid] == nil, "the descendant \(pid) is still running")
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// acpx's `runWithOwnership`: a step that failed on its own keeps its error when the
    /// interrupt comes while its command is still being stopped — here, a child deaf to
    /// the SIGTERM its attempt sent, until the SIGKILL a second later. The run fails with
    /// that error, as acpx 0.19.3 does, not `Interrupted`.
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func aStepThatFailedOnItsOwnKeepsItsErrorThroughAnInterrupt() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "failed-then-interrupted", startAt: "work", nodes: {
              work: shell({ timeoutMs: 0, exec: () => ({ command: "/bin/sh", timeoutMs: 0, args: ["-c",
                `(trap 'printf x > ${JSON.stringify(READY)}' TERM; while :; do sleep 0.1; done) & exit 1`] }) }) },
              edges: [] });
            """, interrupting: true)
        #expect(run.code == 1)
        #expect(run.err.hasPrefix("Shell action failed (/bin/sh \"-c\" \"(trap"), "\(run.err)")
        #expect(member(run.state, "results", "work", "outcome") == .text("failed"))
        let error = try #require(member(run.state, "error")?.stringValue)
        #expect(error.hasPrefix("Shell action failed (/bin/sh") && error.hasSuffix("): exit 1"))
        #expect(member(run.state, "statusDetail") == .text("Failed in work: \(error)"))
        #expect(run.trace.last?["payload"]?["error"] == .text(error))
    }

    /// Interrupted while its title is worked out, the run has not begun and ends at once:
    /// acpx, which listens for the signal only once the steps begin, just exits.
    @Test(.enabled(if: nodeAvailable), .timeLimit(.minutes(1)))
    func anInterruptBeforeTheStepsEndsTheRunAtOnce() async throws {
        let run = try await flowRun("""
            export default defineFlow({ name: "slow-title", startAt: "a",
              run: { title: () => new Promise(() => { fs.writeFileSync(READY, "x"); }) },
              nodes: { a: compute({ run: () => 1 }) }, edges: [] });
            """, interrupting: true)
        #expect(run.code == 130)
        #expect(run.state == nil)
    }
}
