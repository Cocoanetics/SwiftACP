@testable import acpx
import Foundation
import SwiftACP
import Testing

/// Locks the three output formats' rendering of a client operation to acpx's
/// formatters (`output.test.ts`): a permission notice prints `[permission] …` on
/// stdout in text mode, `[acpx] permission: …` on stderr on one line in quiet mode,
/// and the operation itself as a JSON line.
struct OutputRendererTests {
    /// A thread-safe string sink standing in for stdout / stderr.
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
        func write(_ chunk: String) {
            lock.lock()
            buffer += chunk
            lock.unlock()
        }
    }

    static let notice = "Permission cancellation may end the current turn."

    static func permissionNotice(_ summary: String = notice) -> ClientOperation {
        ClientOperation(
            method: ClientOperation.requestPermission, status: .completed, summary: summary,
            timestamp: "2026-09-16T10:31:10.000Z", sessionId: "s")
    }

    /// Render `render` against a fresh renderer in `format`, returning what reached
    /// stdout and stderr. Color is off so the assertions see plain text.
    static func capture(
        _ format: OutputFormat, suppressReads: Bool = false, _ render: (OutputRenderer) -> Void
    ) -> (out: String, err: String) {
        let out = Capture()
        let err = Capture()
        var options = RenderOptions(format: format)
        options.suppressReads = suppressReads
        let renderer = OutputRenderer(options: options, out: out.write, err: err.write, color: false)
        render(renderer)
        return (out.text, err.text)
    }

    @Test func textModePrintsAPermissionSection() {
        let (out, err) = Self.capture(.text) { $0.clientOperation(Self.permissionNotice()) }
        #expect(out == "[permission] \(Self.notice)\n")
        #expect(err.isEmpty)
    }

    @Test func textModeSeparatesTheNoticeFromEarlierOutput() {
        let (out, _) = Self.capture(.text) { renderer in
            renderer.render(.agentMessageChunk(.text("hello")))
            renderer.clientOperation(Self.permissionNotice())
            renderer.finish(stopReason: .endTurn)
        }
        #expect(out == "hello\n\n[permission] \(Self.notice)\n\n[done] end_turn\n")
    }

    @Test func quietModeWritesOneLineToStderr() {
        let (out, err) = Self.capture(.quiet) {
            $0.clientOperation(Self.permissionNotice("line one\r\nline two\nline three"))
        }
        #expect(err == "[acpx] permission: line one line two line three\n")
        #expect(out.isEmpty)
    }

    @Test func jsonModeEmitsTheOperationAsALine() throws {
        let (out, err) = Self.capture(.json) { $0.clientOperation(Self.permissionNotice()) }
        #expect(out.hasSuffix("\n"))
        #expect(!out.dropLast().contains("\n"))
        let decoded = try JSONDecoder().decode(ClientOperation.self, from: Data(out.utf8))
        #expect(decoded == Self.permissionNotice())
        #expect(err.isEmpty)
    }

    /// Only chunks of text are shown, as acpx's text and quiet formatters show them: an
    /// embedded resource's text, which the session's record keeps, is no output's.
    @Test func onlyChunksOfTextAreShown() {
        let resource = ContentBlock.resource(EmbeddedResource(
            resource: ResourceContents(uri: "file:///notes.txt", text: "RESOURCE TEXT ")))
        let chunks: (OutputRenderer) -> Void = { renderer in
            renderer.render(.agentThoughtChunk(resource))
            renderer.render(.agentThoughtChunk(.text("thinking")))
            renderer.render(.agentMessageChunk(resource))
            renderer.render(.agentMessageChunk(.text("plain text")))
            renderer.finish(stopReason: .endTurn)
        }
        let (quiet, _) = Self.capture(.quiet, chunks)
        #expect(quiet == "plain text\n")
        let (text, _) = Self.capture(.text, chunks)
        #expect(!text.contains("RESOURCE TEXT"))
        #expect(text.contains("thinking") && text.contains("plain text"))
        // An answer of no text at all is an empty line in quiet mode, as acpx's quiet
        // formatter writes it at the prompt's answer (`flushBufferedOutput(true)`).
        let (resourceOnly, _) = Self.capture(.quiet) { renderer in
            renderer.render(.agentMessageChunk(resource))
            renderer.finish(stopReason: .endTurn)
        }
        #expect(resourceOnly == "\n")
    }

    /// A tool update acpx's ACP SDK refuses — without the `toolCallId` or `title` its schema
    /// requires — is shown all the same, as acpx's formatter shows the wire message as it came:
    /// what acpx 0.19.3 printed for these updates (#175). Without a `toolCallId` the tool is
    /// `undefined`, one state for every such update; a numeric id is not its text's tool.
    @Test func toolUpdatesTheSDKRefusesAreShownAsAcpxShowsThem() throws {
        let updates = try [
            #"{"sessionUpdate":"tool_call","title":"Read","status":"pending"}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":"t1","status":"in_progress"}"#,
            #"{"sessionUpdate":"tool_call_update","status":"completed","rawInput":{"path":"/x"}}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":5,"status":"pending"}"#,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"5","title":"Five","status":"in_progress"}"#
        ].map { try JSONDecoder().decode(SessionUpdate.self, from: Data($0.utf8)) }
        let (text, err) = Self.capture(.text) { renderer in updates.forEach { renderer.render($0) } }
        #expect(text == """
            [tool] Read (pending)

            [tool] t1 (running)

            [tool] Read (completed)
              input: /x

            [tool] 5 (pending)

            [tool] Five (running)

            """)
        #expect(err.isEmpty)
    }

    /// A refused update's `toolCallId` can be any JSON value. It names its tool as acpx 0.19.3's
    /// `Map` keys it, and shows as JavaScript's `String()` shows it (#270 review):
    /// - a number as JavaScript prints it, `1e20` too, rather than trapping;
    /// - each object or array a new tool;
    /// - `5` and `5.0` one tool, `5` and `[5]` two;
    /// - one `null`, and `true` apart from `"true"`.
    /// A status or kind of another type reads as JavaScript's text of it. Each case is what acpx
    /// printed for the same updates.
    @Test func refusedUpdatesNameTheirToolAsAcpxsMapKeysIt() throws {
        let cases: [(updates: [String], printed: String)] = [
            ([#"{"sessionUpdate":"tool_call","toolCallId":1e20,"status":"pending"}"#,
              #"{"sessionUpdate":"tool_call","toolCallId":1e21,"status":"pending"}"#,
              #"{"sessionUpdate":"tool_call","toolCallId":0.1,"status":"pending"}"#],
             "[tool] 100000000000000000000 (pending)\n\n[tool] 1e+21 (pending)\n\n[tool] 0.1 (pending)\n"),
            ([#"{"sessionUpdate":"tool_call","toolCallId":{},"title":"A","status":"pending"}"#,
              #"{"sessionUpdate":"tool_call_update","toolCallId":{},"status":"in_progress"}"#],
             "[tool] A (pending)\n\n[tool] [object Object] (running)\n"),
            ([#"{"sessionUpdate":"tool_call","toolCallId":5,"status":"pending"}"#,
              #"{"sessionUpdate":"tool_call_update","toolCallId":[5],"status":"in_progress"}"#,
              #"{"sessionUpdate":"tool_call_update","toolCallId":5.0,"status":"in_progress"}"#],
             "[tool] 5 (pending)\n\n[tool] 5 (running)\n"),
            ([#"{"sessionUpdate":"tool_call","title":"T","status":1e20,"kind":1e20}"#,
              #"{"sessionUpdate":"tool_call_update","status":"completed","kind":[1,[2,null],{}]}"#],
             "[tool] T (running)\n\n[tool] T (completed)\n  kind: 1,2,,[object Object]\n"),
            ([#"{"sessionUpdate":"tool_call","toolCallId":null,"title":"N","status":"pending"}"#,
              #"{"sessionUpdate":"tool_call_update","toolCallId":null,"status":"in_progress"}"#,
              #"{"sessionUpdate":"tool_call","toolCallId":true,"status":"pending"}"#,
              #"{"sessionUpdate":"tool_call_update","toolCallId":"true","status":"in_progress"}"#],
             "[tool] N (pending)\n\n[tool] true (pending)\n\n[tool] true (running)\n")
        ]
        for (json, printed) in cases {
            let updates = try json.map { try JSONDecoder().decode(SessionUpdate.self, from: Data($0.utf8)) }
            let (text, _) = Self.capture(.text) { renderer in updates.forEach { renderer.render($0) } }
            #expect(text == printed, "\(json)")
        }
    }

    /// A refused update's `locations` and `content` keep the entries that read, a malformed one
    /// left out, and one that is no list replaces what came before: what acpx 0.19.3 printed for
    /// the same updates (#270 review).
    @Test func refusedUpdatesListsKeepTheirGoodEntries() throws {
        let cases: [(updates: [String], printed: String)] = [
            ([#"{"sessionUpdate":"tool_call","title":"L","status":"in_progress","#
              + #""locations":[{"path":"/a"},{"line":1},{"path":"/b","line":3}]}"#,
              #"{"sessionUpdate":"tool_call_update","status":"completed","#
              + #""content":[{"type":"content","content":{"type":"text","text":"ok"}},{"type":"bogus"}]}"#],
             "[tool] L (running)\n  files: /a, /b:3\n\n[tool] L (completed)\n  files: /a, /b:3\n  output:\n    ok\n"),
            ([#"{"sessionUpdate":"tool_call","title":"M","status":"in_progress","locations":[{"path":"/a"}]}"#,
              #"{"sessionUpdate":"tool_call_update","status":"completed","locations":"x","#
              + #""content":[{"type":"bogus"},{"type":"content","content":{"type":"text","text":"second"}}]}"#],
             "[tool] M (running)\n  files: /a\n\n[tool] M (completed)\n  output:\n    second\n")
        ]
        for (json, printed) in cases {
            let updates = try json.map { try JSONDecoder().decode(SessionUpdate.self, from: Data($0.utf8)) }
            let (text, _) = Self.capture(.text) { renderer in updates.forEach { renderer.render($0) } }
            #expect(text == printed, "\(json)")
        }
    }

    /// A refused update's status that is no string is none of the statuses its text names: acpx
    /// keeps the value, and its strict comparisons find no finished or pending tool — running, as
    /// acpx 0.19.3 printed it. A kind that is no string still shows as its text (#270 review).
    @Test func aRefusedStatusThatIsNoStringIsNoStatus() throws {
        let updates = try [
            #"{"sessionUpdate":"tool_call","title":"S","status":["completed"]}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":"x2","status":["failed"]}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":"x3","status":["pending"]}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":"x4","status":"completed","kind":["read"]}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":"z1","status":"completed","kind":"\u0000read"}"#
        ].map { try JSONDecoder().decode(SessionUpdate.self, from: Data($0.utf8)) }
        let (text, _) = Self.capture(.text) { renderer in updates.forEach { renderer.render($0) } }
        // A string kind is kept as sent, whatever its first character.
        #expect(text == """
            [tool] S (running)

            [tool] x2 (running)

            [tool] x3 (running)

            [tool] x4 (completed)
              kind: read

            [tool] z1 (completed)
              kind: \u{0}read

            """)
    }

    /// A kind that is no string names no kind: under `--suppress-reads` its output is shown, where
    /// the kind `read` hides it. acpx itself throws on such a kind there (its `kind.trim()` is no
    /// function), so this is SwiftACP's own choice, and does not end the output.
    @Test func aKindThatIsNoStringIsNoRead() throws {
        let updates = try [
            #"{"sessionUpdate":"tool_call","toolCallId":"r1","status":"completed","kind":"read","rawOutput":"one"}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":"r2","status":"completed","kind":["read"],"rawOutput":"two"}"#
        ].map { try JSONDecoder().decode(SessionUpdate.self, from: Data($0.utf8)) }
        let (text, _) = Self.capture(.text, suppressReads: true) { renderer in updates.forEach { renderer.render($0) } }
        #expect(!text.contains("one"))
        #expect(text.contains("two"))
    }

    /// A tool call's member sent as `null` clears what an earlier update of the tool set, as acpx's
    /// formatter merges it — the status, and a kind or input — where one left out leaves it: what
    /// acpx 0.19.3 printed for these updates (#270 review).
    @Test func aToolCallsNullMembersClearWhatCameBefore() throws {
        let cases: [(updates: [String], printed: String)] = [
            ([#"{"sessionUpdate":"tool_call","toolCallId":"x","status":"completed"}"#,
              #"{"sessionUpdate":"tool_call","toolCallId":"x","title":"Again","status":null}"#],
             "[tool] x (completed)\n\n[tool] Again (running)\n"),
            ([#"{"sessionUpdate":"tool_call","toolCallId":"y","title":"Y","kind":"read","status":"in_progress","#
              + #""rawInput":{"path":"/p"}}"#,
              #"{"sessionUpdate":"tool_call","toolCallId":"y","title":"Y","kind":null,"rawInput":null,"#
              + #""status":"completed"}"#],
             "[tool] Y (running)\n  input: /p\n\n[tool] Y (completed)\n")
        ]
        for (json, printed) in cases {
            let updates = try json.map { try JSONDecoder().decode(SessionUpdate.self, from: Data($0.utf8)) }
            let (text, _) = Self.capture(.text) { renderer in updates.forEach { renderer.render($0) } }
            #expect(text == printed, "\(json)")
        }
    }

    /// Tool ids are told apart by their UTF-16 code units, as JavaScript's `Map` compares strings:
    /// `"é"` and `"e\u{301}"`, one string to Swift, are two tools, what acpx 0.19.3 printed for
    /// these updates (#270 review). Compared as bytes, since Swift's `==` would call them equal.
    @Test func canonicallyEquivalentIDsAreTwoTools() throws {
        let updates = try [
            #"{"sessionUpdate":"tool_call","toolCallId":"é","title":"A","status":"pending"}"#,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"é","status":"in_progress"}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":"é","status":"completed"}"#
        ].map { try JSONDecoder().decode(SessionUpdate.self, from: Data($0.utf8)) }
        let (text, _) = Self.capture(.text) { renderer in updates.forEach { renderer.render($0) } }
        let printed = "[tool] A (pending)\n\n[tool] e\u{301} (running)\n\n[tool] e\u{301} (completed)\n"
        #expect(Array(text.utf8) == Array(printed.utf8), "\(text)")
    }

    @Test func otherOperationsRenderAsClientLines() {
        let operation = ClientOperation(
            method: "fs/read_text_file", status: .failed, summary: "read /missing.txt",
            details: "no such file\nor directory", timestamp: "2026-09-16T10:31:10.000Z")
        let (text, textErr) = Self.capture(.text) { $0.clientOperation(operation) }
        #expect(text == "[client] read /missing.txt (failed)\n  details:\n    no such file\n    or directory\n")
        #expect(textErr.isEmpty)
        // Quiet mode only ever surfaces permission notices.
        let (quiet, quietErr) = Self.capture(.quiet) { $0.clientOperation(operation) }
        #expect(quiet.isEmpty)
        #expect(quietErr.isEmpty)
    }
}
