@testable import ACPXCore
@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// The small rules of acpx 0.19.3's ACP nodes (#202, step 3): `summarizePrompt`,
/// `createSessionBundleId` and `createIsolatedSessionBinding` (`runtime-support.ts`), the
/// quiet output a turn's text is read from (`createQuietCaptureOutput`), and the session
/// half of the run store (`store.ts`).
struct FlowAcpSupportTests {
    private func summary(_ text: String, _ detail: String? = nil) -> WireJSON {
        FlowRuntimeSupport.summarizePrompt(Array(text.utf16), explicitDetail: detail)
    }

    /// The node's own detail, else `ACP: ` and the prompt's first line with anything in it,
    /// trimmed as JavaScript trims — split on line feeds alone, and cut at 120 UTF-16 units
    /// to 117 and `...`, a surrogate pair included.
    @Test func aPromptIsSummarizedAsAcpxSummarizesIt() {
        #expect(summary("echo hi", "Mine") == .text("Mine"))
        #expect(summary("echo hi", "") == .text("ACP: echo hi"))
        #expect(summary(" \n\u{00A0}\t\n  second line \r\nthird") == .text("ACP: second line"))
        #expect(summary("") == .text("Running ACP prompt"))
        #expect(summary(" \n \n") == .text("Running ACP prompt"))
        let exact = String(repeating: "a", count: 120)
        #expect(summary(exact) == .text("ACP: " + exact))
        #expect(summary(exact + "b") == .text("ACP: " + String(repeating: "a", count: 117) + "..."))
        // 116 units, then a surrogate pair: the cut keeps its first half, as JavaScript's does.
        let pair = String(repeating: "a", count: 116) + "😀" + String(repeating: "b", count: 10)
        #expect(summary(pair) == .string(Array("ACP: ".utf16) + Array(repeating: 0x61, count: 116) + [0xD83D]
            + Array("...".utf16)))
    }

    /// A session's bundle id is its handle as a slug — `session` for none — and the first
    /// eight hex digits of a SHA-1 of its key; an isolated one's handle names the attempt,
    /// its key the working directory too.
    @Test func sessionsAreNamedAsAcpxNamesThem() {
        #expect(FlowRuntimeSupport.createSessionBundleId(handle: "", key: "k") == "session-13fbd79c")
        #expect(FlowRuntimeSupport.createSessionBundleId(handle: "!!", key: "k") == "session-13fbd79c")
        #expect(FlowRuntimeSupport.createSessionBundleId(handle: " Main Handle!", key: "k") == "main-handle-13fbd79c")
        let binding = FlowSessionBinding.isolated(
            flowName: "demo", runId: "2026-01-01T000000000Z-demo-0badcafe", attemptId: "ask#1", profile: nil,
            agent: FlowAgent(agentName: "codex", agentCommand: "codex-acp", agentArgv: ["codex-acp"], cwd: "/work"))
        #expect(binding.bundleId == "isolated-ask-1-f4475733")
        #expect(binding.name == "demo-ask#1-0badcafe")
        #expect(binding.wire == .object([
            ("key", .text("isolated::ask#1")), ("handle", .text("isolated")), ("bundleId", .text(binding.bundleId)),
            ("name", .text("demo-ask#1-0badcafe")), ("agentName", .text("codex")), ("agentCommand", .text("codex-acp")),
            ("agentArgv", .array([.text("codex-acp")])), ("cwd", .text("/work")),
            ("acpxRecordId", .text("isolated::ask#1")), ("acpSessionId", .text("isolated::ask#1"))
        ]))
    }

    // MARK: - The turn's quiet output

    private func chunk(_ text: String, type: String = "text", sessionId: String = "s") -> WireJSON {
        .object([
            ("jsonrpc", .text("2.0")), ("method", .text("session/update")),
            ("params", .object([
                ("sessionId", .text(sessionId)),
                ("update", .object([
                    ("sessionUpdate", .text("agent_message_chunk")),
                    ("content", .object([("type", .text(type)), ("text", .text(text))]))
                ]))
            ]))
        ])
    }

    private func answer(_ result: String) throws -> WireJSON {
        try WireJSON.parse(#"{"jsonrpc":"2.0","id":2,"result":\#(result)}"#)
    }

    /// The answer is the text of the agent's message chunks until the prompt's answer —
    /// each chunk a text one, in a notification of a session — trimmed; one after it is
    /// not the answer's.
    @Test func theAnswerIsTheTextBeforeThePromptsAnswer() throws {
        let capture = FlowQuietCapture(errorOutput: { _ in })
        capture.take(chunk("  Hello"))
        capture.take(chunk("image", type: "image"))
        capture.take(chunk("not a session's", sessionId: ""))
        capture.take(chunk(", world  \n"))
        capture.take(try answer(#"{"stopReason":"end_turn"}"#))
        capture.take(chunk(" and later"))
        capture.flush()
        #expect(capture.read() == Array("Hello, world".utf16))
    }

    /// With no answer, what was said is the answer once the turn ends; an answer after
    /// nothing said is an empty line, written once.
    @Test func whatWasSaidIsKeptHoweverTheTurnEnds() throws {
        let unanswered = FlowQuietCapture(errorOutput: { _ in })
        unanswered.take(chunk("partial"))
        unanswered.flush()
        #expect(unanswered.read() == Array("partial".utf16))
        let silent = FlowQuietCapture(errorOutput: { _ in })
        silent.take(try answer(#"{"stopReason":"end_turn"}"#))
        silent.flush()
        #expect(silent.read().isEmpty)
    }

    /// A permission notice goes to stderr as it comes, on one line; the prompt's usage and
    /// cost once, with the first answer.
    @Test func theQuietOutputReportsOnStderr() throws {
        let lines = Lines()
        let capture = FlowQuietCapture(errorOutput: lines.add)
        capture.take(try WireJSON.parse(
            #"{"jsonrpc":"2.0","id":"p","result":{"_meta":{"acpx":{"permissionNotice":"one\r\ntwo\rthree\nfour"}}}}"#))
        capture.take(try answer(#"{"stopReason":"end_turn","usage":{"totalTokens":9},"cost":2}"#))
        capture.take(try answer(#"{"stopReason":"end_turn","usage":{"totalTokens":1}}"#))
        #expect(lines.all == [
            "[acpx] permission: one two three four\n", "[acpx] tokens: total=9\n", "[acpx] cost: 2\n"
        ])
    }

    // MARK: - Sessions in the bundle

    private func read(_ file: URL) throws -> WireJSON {
        try WireJSON.parse(String(contentsOf: file, encoding: .utf8))
    }

    /// A session is entered in the manifest, its binding kept as an artifact and announced,
    /// the first time only; its `binding.json` is the binding as it is now. Its events are
    /// numbered on across turns, and its record carries the last one written.
    @Test func aSessionIsBundledOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flow-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var store = FlowRunStore(outputRoot: root)
        let runDir = try store.createRunDir("run-1")
        let state = FlowRunState(
            runId: "run-1", flowName: "f", runTitle: nil, flowPath: nil, input: .json(.null), now: "t")
        try store.initializeRunBundle(runDir, snapshot: .object([WireJSON.Member]()), state: state, inputArtifact: nil)
        var binding = FlowSessionBinding.isolated(
            flowName: "f", runId: "run-1", attemptId: "a#1", profile: nil,
            agent: FlowAgent(agentName: "x", agentCommand: "x", agentArgv: nil, cwd: "/"))
        try store.ensureSessionBundle(runDir, state, binding)
        binding.acpxRecordId = "later"
        try store.ensureSessionBundle(runDir, state, binding)
        let manifest = try read(runDir.appendingPathComponent("manifest.json"))
        #expect(manifest["sessions"]?.arrayCount == 1)
        let directory = runDir.appendingPathComponent("sessions/\(binding.bundleId)")
        let current = try read(directory.appendingPathComponent("binding.json"))
        #expect(current["acpxRecordId"] == .text("later"))
        let trace = try String(contentsOf: runDir.appendingPathComponent("trace.ndjson"), encoding: .utf8)
            .split(separator: "\n").map { try WireJSON.parse(String($0)) }
        #expect(trace.filter { $0["type"] == .text("session_bound") }.count == 1)
        let artifact = try #require(trace.last?["payload"]?["bindingArtifact"]?["path"]?.stringValue)
        let first = try read(runDir.appendingPathComponent(artifact))
        #expect(first["acpxRecordId"] == .text("isolated::a#1"))

        let one = store.sessionEventLog(runDir, binding)
        #expect(try one.append(outbound: true, .object([WireJSON.Member]())) == 1)
        #expect(try one.append(outbound: false, .object([WireJSON.Member]())) == 2)
        #expect(try store.sessionEventLog(runDir, binding).append(outbound: true, .null) == 3)
        try store.writeSessionRecord(runDir, binding, .object([
            ("lastSeq", .number(0)), ("eventLog", .object([("active_path", .text("elsewhere"))]))
        ]))
        let record = try read(directory.appendingPathComponent("record.json"))
        #expect(record == .object([
            ("lastSeq", .number(3)),
            ("eventLog", .object([
                ("active_path", .text("sessions/\(binding.bundleId)/events.ndjson")), ("segment_count", .number(1)),
                ("max_segments", .number(1))
            ]))
        ]))
        let events = try String(contentsOf: directory.appendingPathComponent("events.ndjson"), encoding: .utf8)
        #expect(events.split(separator: "\n").map { try? WireJSON.parse(String($0))["direction"] } == [
            .text("outbound"), .text("inbound"), .text("outbound")
        ])
    }
}
