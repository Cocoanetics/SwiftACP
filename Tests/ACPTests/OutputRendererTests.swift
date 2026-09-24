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
