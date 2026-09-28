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
