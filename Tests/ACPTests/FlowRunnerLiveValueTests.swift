@testable import ACPXCore
@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// A flow's outputs and input as acpx writes them (#206): the objects the flow's code holds,
/// as they are whenever the runner writes its state — through `ctx.outputs` or `ctx.input`, on a
/// timer, or in a title function — and a failure when JSON can no longer write one.
struct FlowRunnerLiveValueTests {
    typealias Run = FlowRunnerHarness.Run

    private func runnerRun(_ body: String, input: WireJSON = .object([WireJSON.Member]())) async throws -> Run {
        try await FlowRunnerHarness.run(body, input: input)
    }

    private func member(_ value: WireJSON?, _ path: String...) -> WireJSON? {
        path.reduce(value) { $0?[$1] }
    }

    /// A step's value changed as it returns — on a timer its callback set — is recorded so: its
    /// step and the `node_outcome` event hold it, as acpx writes the object itself when it
    /// records the step (#206 review).
    @Test(.enabled(if: nodeAvailable))
    func aStepsValueChangedAsItReturnsIsRecordedSo() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-soon", startAt: "collect", nodes: {
              collect: compute({ run: () => {
                const value = { items: [] }; setImmediate(() => value.items.push("soon")); return value; } }) },
              edges: [] });
            """)
        #expect(run.code == 0, "\(run.err)")
        let soon = WireJSON.array([.text("soon")])
        let outcome = run.trace.first { $0["type"]?.stringValue == "node_outcome" }
        #expect(member(outcome, "payload", "outputInline", "items") == soon)
        guard case .array(let steps)? = run.state?["steps"] else { throw FlowRunError("no steps") }
        #expect(member(steps.first, "output", "items") == soon)
    }

    /// A title function is handed the run's input itself, as acpx's is: a change it makes is the
    /// input the run's state and its input artifact hold (#206 review).
    @Test(.enabled(if: nodeAvailable))
    func aTitleFunctionsChangeToTheInputIsTheRuns() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-title",
              run: { title: ({ input }) => { input.titled = true; return "Titled"; } }, startAt: "a",
              nodes: { a: compute({ run: ({ input }) => input }) }, edges: [] });
            """, input: .object([("given", .text("yes"))]))
        #expect(run.code == 0, "\(run.err)")
        let changed = WireJSON.object([("given", .text("yes")), ("titled", .bool(true))])
        #expect(member(run.state, "input") == changed)
        let started = run.trace.first { $0["type"]?.stringValue == "run_started" }
        let artifact = try #require(member(started, "payload", "inputArtifact", "path")?.stringValue)
        #expect(try WireJSON.parse(try #require(run.files[artifact])) == changed)
    }

    /// `outputs` is written as `JSON.stringify` writes the flow's own: what a `toJSON` a node put
    /// on it returns — an array here — and nothing at all for `undefined` (#206 review).
    @Test(.enabled(if: nodeAvailable), arguments: [("[1, 2]", #"[1,2]"#), ("undefined", nil)])
    func anOutputsToJSONIsWrittenAsItReturns(_ returned: String, _ written: String?) async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-tojson", startAt: "a", nodes: {
              a: compute({ run: () => "first" }),
              b: compute({ run: ({ outputs }) => { outputs.toJSON = () => \(returned); return "second"; } }) },
              edges: [{ from: "a", to: "b" }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs")?.stringified == written)
        #expect(run.state?.hasMember("outputs") == (written != nil))
    }

    /// A node's output stays the object its callback returned: a later node that changes it
    /// through `ctx.outputs` changes it in every projection written after — `outputs`, the
    /// node's result and its step — as acpx's run state holds the object itself (#206).
    @Test(.enabled(if: nodeAvailable))
    func anOutputChangedAfterItsStepIsWrittenAsItIsNow() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-output", startAt: "collect", nodes: {
              collect: compute({ run: () => ({ items: [] }) }),
              add: compute({ run: ({ outputs }) => { outputs.collect.items.push("x"); return "added"; } }) },
              edges: [{ from: "collect", to: "add" }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        let items = WireJSON.array([.text("x")])
        #expect(member(run.state, "outputs", "collect", "items") == items)
        #expect(member(run.state, "results", "collect", "output", "items") == items)
        guard case .array(let steps)? = run.state?["steps"] else { throw FlowRunError("no steps") }
        #expect(member(steps.first, "output", "items") == items)
        #expect(member(steps.first, "trace", "outputInline", "items") == items)
    }

    /// `ctx.outputs` is the run's own `outputs`, as acpx hands its callbacks `state.outputs`: a
    /// member a later node replaces, deletes or adds is so in every projection written after,
    /// while the replaced node's result and step keep the value its step produced (#206 review).
    @Test(.enabled(if: nodeAvailable))
    func anOutputReplacedThroughCtxOutputsIsTheRunsOutput() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-replace", startAt: "collect", nodes: {
              collect: compute({ run: () => ({ items: ["old"] }) }),
              other: compute({ run: () => "kept" }),
              change: compute({ run: ({ outputs }) => {
                outputs.collect = { items: ["new"] }; delete outputs.other; outputs.extra = { added: true };
                return "changed"; } }) },
              edges: [{ from: "collect", to: "other" }, { from: "other", to: "change" }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs")?.stringified
            == #"{"collect":{"items":["new"]},"extra":{"added":true},"change":"changed"}"#)
        #expect(member(run.state, "results", "collect", "output")?.stringified == #"{"items":["old"]}"#)
        #expect(member(run.state, "results", "other", "output") == .text("kept"))
    }

    /// The run's input stays the object it was given: a node that changes it through
    /// `ctx.input` changes the input every projection written after holds (#206).
    @Test(.enabled(if: nodeAvailable))
    func anInputChangedByANodeIsWrittenAsItIsNow() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-input", startAt: "mark", nodes: {
              mark: compute({ run: ({ input }) => { input.seen = true; return 1; } }) }, edges: [] });
            """, input: .object([("given", .text("yes"))]))
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "input") == .object([("given", .text("yes")), ("seen", .bool(true))]))
    }

    /// A value an output can no longer be written with — a BigInt a later node adds to it —
    /// fails the next snapshot and the run with it, as acpx's `JSON.stringify` of its state
    /// throws as it writes: the bundle stays as it last was (#206).
    @Test(.enabled(if: nodeAvailable))
    func anOutputJSONCanNoLongerWriteFailsTheRun() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-bigint", startAt: "collect", nodes: {
              collect: compute({ run: () => ({ items: [] }) }),
              add: compute({ run: ({ outputs }) => { outputs.collect.items.push(1n); return "added"; } }),
              after: compute({ run: () => "after" }) },
              edges: [{ from: "collect", to: "add" }, { from: "add", to: "after" }] });
            """)
        #expect(run.code == 1)
        #expect(run.err == "Do not know how to serialize a BigInt")
        #expect(member(run.state, "status") == .text("running"))
        #expect(run.trace.last?["type"] == .text("node_started"))
        #expect(run.trace.last?["nodeId"] == .text("add"))
    }

    /// A checkpoint's waiting state holds `outputs` as the flow's code does — here a `toJSON` an
    /// earlier node put on it — though it is written as the checkpoint's output is committed
    /// (#206 review).
    @Test(.enabled(if: nodeAvailable))
    func aCheckpointsWaitingStateKeepsOutputsOwnJSON() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-tojson-checkpoint", startAt: "a", nodes: {
              a: compute({ run: ({ outputs }) => { outputs.toJSON = () => ["custom"]; return "first"; } }),
              wait: checkpoint({ summary: "Waiting here" }) },
              edges: [{ from: "a", to: "wait" }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "status") == .text("waiting"))
        #expect(member(run.state, "outputs") == .array([.text("custom")]))
    }

    /// An output JSON no longer has anything for — its `toJSON` now returns `undefined` — is left
    /// out wherever it was recorded: its node's result, its step and the step's `outputInline`,
    /// and `outputs`, as `JSON.stringify` of acpx's state leaves it out (#206 review).
    @Test(.enabled(if: nodeAvailable))
    func anOutputJSONNoLongerWritesIsLeftOut() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-output-omitted", startAt: "a", nodes: {
              a: compute({ run: () => ({ x: 1 }) }),
              b: compute({ run: ({ outputs }) => { outputs.a.toJSON = () => undefined; return "second"; } }) },
              edges: [{ from: "a", to: "b" }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        #expect(member(run.state, "outputs")?.stringified == #"{"b":"second"}"#)
        #expect(member(run.state, "results", "a")?.hasMember("output") == false)
        guard case .array(let steps)? = run.state?["steps"] else { throw FlowRunError("no steps") }
        #expect(steps.first?.hasMember("output") == false)
        #expect(member(steps.first, "trace")?.hasMember("outputInline") == false)
        #expect(try WireJSON.parse(try #require(run.files["projections/steps.json"])) == .array(steps))
    }

    /// An input JSON has nothing for — its `toJSON` returns `undefined` — is left out of the
    /// run's state, as `JSON.stringify` of acpx's leaves it out; set so by a title function, the
    /// input artifact reads `undefined`, as acpx's `writeArtifact` writes it (#206 review).
    @Test(.enabled(if: nodeAvailable), arguments: [false, true])
    func anInputJSONHasNothingForIsLeftOut(byTitle: Bool) async throws {
        let leave = "input.toJSON = () => undefined;"
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-input-gone",
              run: { title: ({ input }) => { \(byTitle ? leave : "") return "Titled"; } }, startAt: "a",
              nodes: { a: compute({ run: ({ input }) => { \(byTitle ? "" : leave) return "first"; } }) },
              edges: [] });
            """, input: .object([("given", .text("yes"))]))
        #expect(run.code == 0, "\(run.err)")
        #expect(run.state?.hasMember("input") == false)
        #expect(run.state?.hasMember("outputs") == true)
        let started = run.trace.first { $0["type"]?.stringValue == "run_started" }
        let artifact = try #require(member(started, "payload", "inputArtifact", "path")?.stringValue)
        #expect(run.files[artifact] == (byTitle ? "undefined\n" : "{\n  \"given\": \"yes\"\n}\n"))
    }

    /// An output JSON had nothing for as its step ended keeps its place in the step and its
    /// node's result, as acpx's state holds the object itself: given JSON again by a later node,
    /// it is written there (#206 review).
    @Test(.enabled(if: nodeAvailable))
    func anOutputWithoutJSONKeepsItsPlace() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-omitted-returns", startAt: "a", nodes: {
              a: compute({ run: () => ({ x: 1, toJSON: () => undefined }) }),
              b: compute({ run: ({ outputs }) => { outputs.a.toJSON = () => ({ back: true }); return "second"; } }) },
              edges: [{ from: "a", to: "b" }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        let back = WireJSON.object([("back", .bool(true))])
        guard case .array(let steps)? = run.state?["steps"] else { throw FlowRunError("no steps") }
        #expect(member(steps.first, "output") == back)
        #expect(steps.first?.objectMembers.map { String(decoding: $0.key, as: UTF16.self) } == [
            "attemptId", "nodeId", "nodeType", "outcome", "startedAt", "finishedAt", "promptText", "rawText",
            "output", "session", "agent", "trace"
        ])
        #expect(member(run.state, "results", "a", "output") == back)
        #expect(member(steps.first, "trace")?.hasMember("outputArtifact") == true)
    }

    /// An output JSON had nothing for still fails the run once JSON throws for it — a BigInt a
    /// later `toJSON` returns — though no member of `outputs` holds it any more: acpx's step and
    /// result still do, and its write of them throws (#206 review).
    @Test(.enabled(if: nodeAvailable))
    func anOutputWithoutJSONStillFailsTheRunOnceJSONThrows() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-omitted-bigint", startAt: "a", nodes: {
              a: compute({ run: () => ({ x: 1, toJSON: () => undefined }) }),
              b: compute({ run: ({ outputs }) => {
                const kept = outputs.a; delete outputs.a; kept.toJSON = () => 1n; return "second"; } }),
              c: compute({ run: () => "after" }) },
              edges: [{ from: "a", to: "b" }, { from: "b", to: "c" }] });
            """)
        #expect(run.code == 1)
        #expect(run.err == "Do not know how to serialize a BigInt")
        #expect(member(run.state, "status") == .text("running"))
        #expect(run.trace.last?["nodeId"] == .text("b"))
    }

    /// An `outputInline` keeps its place while its output has no JSON — set so as its step is
    /// recorded — and is written there again once a later node gives it JSON; the step's
    /// `node_outcome`, written meanwhile, leaves it out (#206 review).
    @Test(.enabled(if: nodeAvailable))
    func anOutputInlineKeepsItsPlaceWhileItsOutputHasNoJSON() async throws {
        let run = try await runnerRun("""
            export default defineFlow({ name: "live-inline-slot", startAt: "a", nodes: {
              a: compute({ run: () => {
                const value = { x: 1 }; setImmediate(() => { value.toJSON = () => undefined; }); return value; } }),
              b: compute({ run: ({ outputs }) => { outputs.a.toJSON = () => ({ y: 2 }); return "second"; } }) },
              edges: [{ from: "a", to: "b" }] });
            """)
        #expect(run.code == 0, "\(run.err)")
        let later = WireJSON.object([("y", .number(2))])
        guard case .array(let steps)? = run.state?["steps"] else { throw FlowRunError("no steps") }
        #expect(member(steps.first, "output") == later)
        #expect(member(steps.first, "trace") == .object([("outputInline", later)]))
        let outcome = run.trace.first { $0["type"]?.stringValue == "node_outcome" && $0["nodeId"] == .text("a") }
        #expect(member(outcome, "payload")?.hasMember("outputInline") == false)
    }
}
