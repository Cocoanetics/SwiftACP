@testable import ACPXCore
@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// An isolated ACP node as acpx 0.19.3's runner runs one (#202, step 3): the prompt made
/// in the host, the turn — here a scripted one (``ScriptedTurn``) — every ACP message of it
/// in the bundle, and the session published however the turn ended. Run by the runner
/// itself, as `FlowRunnerTests` are; `FlowAcpRunTests` has the CLI with a real agent.
struct FlowAcpRunnerTests {
    typealias Run = FlowRunnerHarness.Run

    private func member(_ value: WireJSON?, _ path: String...) -> WireJSON? {
        path.reduce(value) { $0?[$1] }
    }

    private func lines(_ text: String?) -> [WireJSON] {
        (text ?? "").split(separator: "\n").compactMap { try? WireJSON.parse(String($0)) }
    }

    /// The one session of a run: its binding, record and events.
    struct Session {
        let binding: WireJSON
        let record: WireJSON
        let events: [WireJSON]
        let id: String
    }

    private func session(_ run: Run) throws -> Session {
        let path = try #require(run.files.keys.first { $0.hasSuffix("/binding.json") })
        let directory = String(path.dropLast("/binding.json".count))
        return Session(
            binding: try WireJSON.parse(try #require(run.files[path])),
            record: try WireJSON.parse(try #require(run.files["\(directory)/record.json"])),
            events: lines(run.files["\(directory)/events.ndjson"]), id: String(directory.dropFirst("sessions/".count)))
    }

    private func types(_ run: Run) -> [String] {
        run.trace.compactMap { $0["type"]?.stringValue }
    }

    /// No periodic heartbeat, which a slow machine's step could outlast.
    private static let node = """
        export default defineFlow({ name: "turn", startAt: "ask", nodes: {
          ask: acp({ profile: "mock", heartbeatMs: 0, session: { isolated: true }, prompt: () => "echo hi",
            parse: (text) => ({ said: text }) }) }, edges: [] });
        """

    // MARK: - A turn in the bundle

    /// The turn's session opens in the bundle before the turn, is bound as it first was,
    /// and is published once it is over: its binding with the session's id, its record —
    /// the conversation, closed, numbered as the bundle numbers its events — and each ACP
    /// message of it, numbered from 1. The step keeps the prompt's text, the answer, the
    /// session and the agent.
    @Test(.enabled(if: nodeAvailable))
    func anIsolatedTurnIsBundledAsAcpxBundlesIt() async throws {
        let turn = ScriptedTurn(ScriptedTurn.answering("hi there"))
        let run = try await FlowRunnerHarness.run(Self.node, sessions: turn)
        #expect(run.code == 0, "\(run.err)")
        #expect(types(run) == [
            "run_started", "node_started", "node_heartbeat", "artifact_written", "session_bound",
            "acp_prompt_prepared", "artifact_written", "acp_response_parsed", "node_outcome", "run_completed"
        ])
        #expect(run.trace[2]["payload"] == .object([("statusDetail", .text("ACP: echo hi"))]))
        let found = try session(run)
        let (binding, record, events, bundleId) = (found.binding, found.record, found.events, found.id)
        #expect(bundleId.hasPrefix("isolated-ask-1-"))
        #expect(binding["acpxRecordId"] == .text("s-1") && binding["acpSessionId"] == .text("s-1"))
        #expect(binding["key"] == .text("isolated::ask#1"))
        #expect(binding["name"]?.stringValue?.hasPrefix("turn-ask#1-") == true)
        // The binding as it was first bound: the session's key, before it had an id.
        let bound = try #require(run.trace.first { $0["type"] == .text("session_bound") })
        let artifact = try #require(member(bound, "payload", "bindingArtifact", "path")?.stringValue)
        #expect(try WireJSON.parse(try #require(run.files[artifact]))["acpxRecordId"] == .text("isolated::ask#1"))
        #expect(events.map { $0["seq"] } == (1...7).map { .number(Double($0)) })
        #expect(events.map { $0["direction"]?.stringValue } == [
            "outbound", "inbound", "outbound", "inbound", "outbound", "inbound", "inbound"
        ])
        #expect(record["acpxRecordId"] == .text("s-1") && record["closed"] == .bool(true))
        #expect(record["lastSeq"] == .number(7))
        #expect(member(record, "eventLog", "active_path") == .text("sessions/\(bundleId)/events.ndjson"))
        #expect(record["messages"]?.arrayCount == 2)
        #expect(record["acpx"] == .object([WireJSON.Member]()))
        let step = try #require(member(run.state, "steps")?.arrayItems.first)
        #expect(step["promptText"] == .text("echo hi") && step["rawText"] == .text("hi there"))
        #expect(member(step, "session", "acpxRecordId") == .text("s-1"))
        #expect(member(step, "agent") == .object([
            ("agentName", .text("mock")), ("agentCommand", .text("mock-agent")), ("cwd", .text(run.flowDir))
        ]))
        #expect(member(step, "trace", "conversation") == .object([
            ("sessionId", .text(bundleId)), ("messageStart", .number(0)), ("messageEnd", .number(1)),
            ("eventStartSeq", .number(1)), ("eventEndSeq", .number(7))
        ]))
        #expect(member(run.state, "outputs", "ask") == .object([("said", .text("hi there"))]))
        #expect(turn.prompts == [[.text("echo hi")]])
    }

    /// A turn the agent failed is published all the same, and the step keeps what the
    /// agent said before it failed; the run fails with the agent's message.
    @Test(.enabled(if: nodeAvailable))
    func aFailedTurnIsPublishedWithWhatItSaid() async throws {
        let failure = JSONRPCErrorBody(
            code: -32603, message: "Internal error", data: .object(["details": "overloaded"]))
        let turn = ScriptedTurn(Array(ScriptedTurn.answering("partial").dropLast()), ending: .failure(failure))
        let run = try await FlowRunnerHarness.run(Self.node, sessions: turn)
        #expect(run.code == 1)
        #expect(run.err == "Internal error")
        #expect(member(run.state, "results", "ask", "outcome") == .text("failed"))
        let step = try #require(member(run.state, "steps")?.arrayItems.first)
        #expect(step["rawText"] == .text("partial") && step["error"] == .text("Internal error"))
        #expect(member(step, "trace", "rawResponseArtifact") != nil)
        #expect(member(step, "trace", "conversation", "eventEndSeq") == .number(6))
        // The session's id, which the turn had before it failed.
        #expect(member(step, "session", "acpxRecordId") == .text("s-1"))
        let found = try session(run)
        let (record, events) = (found.record, found.events)
        #expect(events.count == 6 && record["lastSeq"] == .number(6))
        #expect(!types(run).contains("acp_response_parsed"))
    }

    /// A turn that sent nothing on the wire — none of its events captured — fails once
    /// published.
    @Test(.enabled(if: nodeAvailable))
    func aTurnWithoutEventsFails() async throws {
        let run = try await FlowRunnerHarness.run(Self.node, sessions: ScriptedTurn([.ready("s-1")]))
        #expect(run.code == 1)
        let bundleId = try session(run).id
        #expect(run.err == "Missing ACP event capture for session \(bundleId)")
        let step = try #require(member(run.state, "steps")?.arrayItems.first)
        #expect(member(step, "trace", "rawResponseArtifact") != nil)
        #expect(member(step, "trace", "conversation") == nil)
    }

    /// The step's deadline stops the turn, which winds down — its prompt cancelled — and is
    /// published before the step fails with the timeout: acpx's attempt waits for the work
    /// it owns, and the step keeps what it published. (The turn times its attempt out
    /// itself, where it waits, as the attempt's timer would.)
    @Test(.enabled(if: nodeAvailable))
    func aTurnStoppedAtItsDeadlineIsPublished() async throws {
        // The turn winds down slowly: the step is recorded only once the turn is over, so a
        // runner that did not wait for the work its attempt owns would record it meanwhile.
        var steps = Array(ScriptedTurn.answering("x").prefix(6))
        steps += [.timeOut(300), .waitForStop, .pause(milliseconds: 300),
                  .outbound(#"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s-1"}}"#),
                  .inbound(#"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"cancelled"}}"#)]
        let run = try await FlowRunnerHarness.run(Self.node, sessions: ScriptedTurn(steps))
        #expect(run.code == 3)
        #expect(run.err == "Timed out after 300ms")
        #expect(member(run.state, "results", "ask", "outcome") == .text("timed_out"))
        let found = try session(run)
        let (binding, record, events) = (found.binding, found.record, found.events)
        #expect(events.last?["message"]?["result"] == .object([("stopReason", .text("cancelled"))]))
        #expect(record["lastSeq"] == .number(7) && binding["acpxRecordId"] == .text("s-1"))
        let step = try #require(member(run.state, "steps")?.arrayItems.first)
        #expect(member(step, "trace", "conversation", "eventEndSeq") == .number(7))
        #expect(member(step, "session", "acpxRecordId") == .text("s-1"))
        #expect(types(run).suffix(3) == ["artifact_written", "node_outcome", "run_failed"])
    }

    /// An interrupt stops a turn as a deadline does.
    @Test(.enabled(if: nodeAvailable))
    func anInterruptedTurnIsPublished() async throws {
        var steps = Array(ScriptedTurn.answering("x").prefix(6))
        steps += [.interrupt, .waitForStop,
                  .inbound(#"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"cancelled"}}"#)]
        let turn = ScriptedTurn(steps)
        let run = try await FlowRunnerHarness.run(Self.node, sessions: turn, runnerReady: turn.interrupts)
        #expect(run.err == "Interrupted")
        #expect(member(run.state, "results", "ask", "outcome") == .text("cancelled"))
        #expect(try session(run).record["lastSeq"] == .number(6))
    }

    /// Stopped before its session was ready, the turn leaves the session its binding's
    /// key: acpx takes the session's id from the prompt's context, not yet set.
    @Test(.enabled(if: nodeAvailable))
    func aTurnStoppedBeforeItsSessionKeepsTheBinding() async throws {
        let turn = ScriptedTurn(
            Array(ScriptedTurn.answering("x").prefix(2)) + [.interrupt, .waitForStop], ending: .stopReason)
        let run = try await FlowRunnerHarness.run("""
            export default defineFlow({ name: "turn", startAt: "ask", nodes: {
              ask: acp({ profile: "mock", session: { isolated: true }, prompt: () => "wait" }) }, edges: [] });
            """, sessions: turn, runnerReady: turn.interrupts)
        #expect(run.err == "Interrupted")
        let found = try session(run)
        let (binding, record) = (found.binding, found.record)
        #expect(binding["acpxRecordId"] == .text("isolated::ask#1"))
        #expect(record["acpxRecordId"] == .text("isolated::ask#1"))
        #expect(record["lastSeq"] == .number(2))
    }

    /// acpx: "times out async ACP prompt callbacks" — a `prompt` that never settles times
    /// the step out, and no turn starts.
    @Test(.enabled(if: nodeAvailable))
    func aPromptThatNeverSettlesTimesOut() async throws {
        let turn = ScriptedTurn(ScriptedTurn.answering("never"))
        let run = try await FlowRunnerHarness.run("""
            export default defineFlow({ name: "prompt-timeout", startAt: "slow", nodes: {
              slow: acp({ session: { isolated: true }, timeoutMs: 50,
                prompt: async () => await new Promise(() => {}) }) }, edges: [] });
            """, sessions: turn)
        #expect(run.code == 3)
        #expect(member(run.state, "results", "slow", "outcome") == .text("timed_out"))
        #expect(turn.prompts.isEmpty)
    }

    /// acpx: "times out async ACP parse callbacks" — a `parse` that never settles times the
    /// step out once the turn's answer is in (its `acp_response_parsed` comes before it).
    /// The attempt times out once `parse` says it has begun, as its timer would then.
    @Test(.enabled(if: nodeAvailable))
    func aParseThatNeverSettlesTimesOut() async throws {
        let begun = FileManager.default.temporaryDirectory.appendingPathComponent("parse-\(UUID().uuidString)")
        let turn = ScriptedTurn(ScriptedTurn.answering("hello"))
        let watch = try Self.whenWritten(begun) { turn.timeOut(2000) }
        defer {
            watch.cancel()
            try? FileManager.default.removeItem(at: begun)
        }
        let run = try await FlowRunnerHarness.run("""
            import fs from "node:fs";
            export default defineFlow({ name: "parse-timeout", startAt: "slow", nodes: {
              slow: acp({ session: { isolated: true }, heartbeatMs: 0, prompt: () => "hello",
                parse: async () => {
                  fs.writeFileSync(\(begun.path.debugDescription), "x");
                  return await new Promise(() => {});
                } }) }, edges: [] });
            """, sessions: turn)
        #expect(run.code == 3)
        #expect(member(run.state, "results", "slow", "outcome") == .text("timed_out"))
        #expect(member(run.state, "results", "slow", "error") == .text("Timed out after 2000ms"))
        #expect(types(run).contains("acp_response_parsed"))
        #expect(member(run.state, "steps")?.arrayItems.first?["rawText"] == .text("hello"))
    }

    /// `action` once a FIFO at `path` is written to. It is read until cancelled, so a
    /// writer never waits.
    static func whenWritten(_ path: URL, _ action: @escaping @Sendable () -> Void) throws -> DispatchSourceRead {
        guard mkfifo(path.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let fd = open(path.path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        let fired = Lines()
        reader.setEventHandler {
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) > 0, fired.all.isEmpty else { return }
            fired.add("fired")
            action()
        }
        reader.setCancelHandler { close(fd) }
        reader.resume()
        return reader
    }

    // MARK: - The prompt

    /// The prompt is made in the host as acpx makes it: a string is a text block, content
    /// blocks go as they are, and making its text fails the step as it fails acpx's — the
    /// agent never started.
    @Test(.enabled(if: nodeAvailable), arguments: [
        ("() => 42", "prompt.map is not a function"), ("() => { throw new Error(\"no prompt\"); }", "no prompt"),
        ("() => [null]", "Cannot read properties of null (reading 'type')"),
        ("() => [{ type: \"text\", text: 5 }]", "entry.trim is not a function")
    ])
    func aPromptThatCannotBeShownFailsTheStep(_ prompt: String, _ message: String) async throws {
        let turn = ScriptedTurn(ScriptedTurn.answering("never"))
        let run = try await FlowRunnerHarness.run("""
            export default defineFlow({ name: "prompt", startAt: "ask", nodes: {
              ask: acp({ profile: "mock", session: { isolated: true }, prompt: \(prompt) }) }, edges: [] });
            """, sessions: turn)
        #expect(run.code == 1)
        #expect(run.err == message)
        #expect(turn.prompts.isEmpty)
        let step = try #require(member(run.state, "steps")?.arrayItems.first)
        #expect(step["session"] == .null && step["promptText"] == .null)
    }

    /// An empty prompt's detail is acpx's for none; content blocks reach the agent whole,
    /// and a block SwiftACP cannot send fails the step, before the agent starts.
    @Test(.enabled(if: nodeAvailable))
    func promptsAreSentAsTheFlowGivesThem() async throws {
        let empty = ScriptedTurn(ScriptedTurn.answering("ok"))
        let run = try await FlowRunnerHarness.run("""
            export default defineFlow({ name: "prompt", startAt: "ask", nodes: {
              ask: acp({ profile: "mock", heartbeatMs: 0, session: { isolated: true }, prompt: () => "" }) },
              edges: [] });
            """, sessions: empty)
        #expect(run.code == 0, "\(run.err)")
        #expect(run.trace[2]["payload"] == .object([("statusDetail", .text("Running ACP prompt"))]))
        #expect(empty.prompts == [[.text("")]])

        let blocks = ScriptedTurn(ScriptedTurn.answering("ok"))
        let sent = try await FlowRunnerHarness.run("""
            export default defineFlow({ name: "prompt", startAt: "ask", nodes: {
              ask: acp({ profile: "mock", session: { isolated: true }, prompt: () => [
                { type: "text", text: "look" }, { type: "resource_link", uri: "file:///a.txt", name: "a.txt" }] }) },
              edges: [] });
            """, sessions: blocks)
        #expect(sent.code == 0, "\(sent.err)")
        #expect(member(sent.state, "steps")?.arrayItems.first?["promptText"] == .text("look\n\na.txt"))
        #expect(blocks.prompts.first?.count == 2)

        let unknown = ScriptedTurn(ScriptedTurn.answering("never"))
        let refused = try await FlowRunnerHarness.run("""
            export default defineFlow({ name: "prompt", startAt: "ask", nodes: {
              ask: acp({ profile: "mock", session: { isolated: true }, prompt: () => [{ type: "video", uri: "x" }] }) },
              edges: [] });
            """, sessions: unknown)
        #expect(refused.code == 1)
        #expect(refused.err == #"SwiftACP cannot send prompt[0] to the agent: {"type":"video","uri":"x"}"#)
        #expect(unknown.prompts.isEmpty)
    }

    /// A node's `cwd` — a string, or what a function returns — is resolved against the
    /// agent's, as `path.resolve` resolves it, and refused as it refuses what is no string.
    @Test(.enabled(if: nodeAvailable))
    func aNodesCwdIsResolvedAgainstTheAgents() async throws {
        for (cwd, expected) in [("\"sub\"", "/sub"), ("() => \"a/../b\"", "/b"), ("() => null", "")] {
            let turn = ScriptedTurn(ScriptedTurn.answering("ok"))
            let run = try await FlowRunnerHarness.run("""
                export default defineFlow({ name: "cwd", startAt: "ask", nodes: {
                  ask: acp({ profile: "mock", cwd: \(cwd), session: { isolated: true }, prompt: () => "hi" }) },
                  edges: [] });
                """, sessions: turn)
            #expect(run.code == 0, "\(run.err)")
            #expect(turn.cwds == [run.flowDir + expected], "\(cwd)")
        }
        let run = try await FlowRunnerHarness.run("""
            export default defineFlow({ name: "cwd", startAt: "ask", nodes: {
              ask: acp({ profile: "mock", cwd: () => 5, session: { isolated: true }, prompt: () => "hi" }) },
              edges: [] });
            """, sessions: ScriptedTurn(ScriptedTurn.answering("never")))
        #expect(run.err == #"The "paths[1]" argument must be of type string. Received type number (5)"#)
    }

    // MARK: - What the turn reports

    /// The turn's quiet output reports on acpx's own stderr, as its quiet formatter does:
    /// a permission notice as it comes, and the prompt's token usage and cost once.
    @Test(.enabled(if: nodeAvailable))
    func theTurnReportsOnStderrAsAcpxsQuietOutputDoes() async throws {
        var steps = Array(ScriptedTurn.answering("done").dropLast())
        steps.insert(.outbound(#"{"jsonrpc":"2.0","id":"p1","result":{"outcome":{"outcome":"cancelled"},"#
            + #""_meta":{"acpx":{"permissionNotice":"refused\nfor now"}}}}"#), at: 5)
        steps.append(.inbound(#"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn","#
            + #""usage":{"inputTokens":3,"outputTokens":4},"cost":{"amount":0.5,"currency":"USD"}}}"#))
        let stderr = Lines()
        let run = try await FlowRunnerHarness.run(Self.node, sessions: ScriptedTurn(steps), errorOutput: stderr.add)
        #expect(run.code == 0, "\(run.err)")
        #expect(stderr.all == [
            "[acpx] permission: refused for now\n", "[acpx] tokens: input=3 output=4\n", "[acpx] cost: 0.5 USD\n"
        ])
    }

    /// The record's conversation is the turn's, and a client operation alone makes its
    /// `acpx` block, as acpx's conversation model makes it for any.
    @Test(.enabled(if: nodeAvailable))
    func aClientOperationMakesTheRecordsAcpxBlock() async throws {
        let quiet = ScriptedTurn(ScriptedTurn.answering("ok").filter { !$0.isUpdate })
        let none = try await FlowRunnerHarness.run(Self.node, sessions: quiet)
        #expect(try session(none).record.hasMember("acpx") == false)
        let operation = ScriptedTurn(ScriptedTurn.answering("ok").filter { !$0.isUpdate } + [.clientOperation])
        let one = try await FlowRunnerHarness.run(Self.node, sessions: operation)
        #expect(try session(one).record["acpx"] == .object([WireJSON.Member]()))
    }

    /// A persistent session is the next step (#202).
    @Test(.enabled(if: nodeAvailable))
    func aPersistentSessionIsRefusedForNow() async throws {
        let run = try await FlowRunnerHarness.run("""
            export default defineFlow({ name: "main", startAt: "ask", nodes: {
              ask: acp({ profile: "mock", prompt: () => "hi" }) }, edges: [] });
            """, sessions: ScriptedTurn(ScriptedTurn.answering("never")))
        #expect(run.err == "ACP nodes with a persistent session are not supported by SwiftACP's acpx yet")
    }
}
