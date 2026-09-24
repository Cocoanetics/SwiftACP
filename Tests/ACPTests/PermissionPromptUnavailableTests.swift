@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// A turn that needed a permission question nobody could be asked fails once over, as
/// acpx fails it, unless the stream already shows the client's refusal saying the same
/// (#93). A refused write shows it, since the refusal is an error on the wire. A tool
/// permission answered `cancelled` does not. Lines are acpx 0.19.1's.
@Suite struct PermissionPromptUnavailableTests {
    static let message = "Permission prompt unavailable in non-interactive mode"

    /// The daemon's turn: text output shows it as the queue owner's error.
    @Test func textOutputShowsTheFailureAfterTheTurn() {
        let (out, err) = OutputRendererTests.capture(.text) { renderer in
            renderer.permissionPromptUnavailable(sessionId: "rec-1")
        }
        #expect(out == "[error] PERMISSION_PROMPT_UNAVAILABLE: \(Self.message)\n")
        #expect(err.isEmpty)
    }

    @Test func jsonOutputPrintsTheQueueOwnersErrorLine() {
        let (out, _) = OutputRendererTests.capture(.json) { renderer in
            renderer.permissionPromptUnavailable(sessionId: "rec-1")
        }
        #expect(out == #"""
            {"jsonrpc":"2.0","id":null,"error":{"code":-32072,"message":"\#(Self.message)",\#
            "data":{"acpxCode":"PERMISSION_PROMPT_UNAVAILABLE","detailCode":"QUEUE_RUNTIME_PROMPT_FAILED",\#
            "origin":"runtime","sessionId":"rec-1"}}}

            """#)
    }

    /// Quiet output is `permissionExitCode`'s one line, not the renderer's.
    @Test func quietOutputLeavesItToTheExitCode() {
        let (out, err) = OutputRendererTests.capture(.quiet) { renderer in
            renderer.permissionPromptUnavailable(sessionId: "rec-1")
        }
        #expect(out.isEmpty && err.isEmpty)
    }

    /// A refused write is on screen already, in text output too: nothing more.
    @Test func aRefusalTheStreamShowedIsNotRepeated() {
        for format in [OutputFormat.text, .json] {
            let (out, _) = OutputRendererTests.capture(format) { renderer in
                renderer.inboundRequest(InboundRequest(method: "fs/write_text_file", failure: Self.message))
                renderer.permissionPromptUnavailable(sessionId: "rec-1")
            }
            #expect(!out.contains("PERMISSION_PROMPT_UNAVAILABLE"), "\(format)")
        }
    }

    /// The text renderer notes the client's refusal as acpx's tracker notes an outbound
    /// error: a failure saying the same is shown, any other is not.
    @Test func aRefusalCountsOnlyForTheFailureThatRepeatsIt() {
        let renderer = OutputRenderer(options: RenderOptions(format: .text), out: { _ in }, err: { _ in }, color: false)
        #expect(!renderer.showedFailure(Self.message))
        renderer.inboundRequest(InboundRequest(method: "fs/write_text_file", failure: Self.message))
        #expect(renderer.showedFailure(Self.message))
        #expect(!renderer.showedFailure("The JSON-RPC connection is closed"))
    }

    /// `exec` end to end, on an agent asking permission for an edit under
    /// `--approve-reads --non-interactive-permissions fail`: it is answered `cancelled`,
    /// and the run fails on the question, as acpx's does — the message on stderr in text
    /// output, its error line in JSON output — with exit 5.
    @Test(.enabled(if: mockPythonAvailable))
    func execFailsOnAnUnanswerableToolQuestion() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/write-agent.py")
        let command = "/usr/bin/env MOCK_TOOL_PERMISSION=1 '\(python)' '\(fixture.path)'"
        let flags = ["--approve-reads", "--non-interactive-permissions", "fail", "--agent", command]
        try await withIsolatedStore {
            let text = Console.Capture()
            let textCode = Console.$capture.withValue(text) { runCommandLine(flags + ["exec", "go"]) }
            #expect(textCode == ExitCodes.permissionDenied)
            #expect(text.out.contains("outcome:cancelled"))
            #expect(text.err.hasSuffix(Self.message + "\n"))

            let json = Console.Capture()
            let jsonCode = Console.$capture.withValue(json) {
                runCommandLine(["--format", "json"] + flags + ["exec", "go"])
            }
            #expect(jsonCode == ExitCodes.permissionDenied)
            #expect(json.out.hasSuffix(#"""
                {"jsonrpc":"2.0","id":null,"error":{"code":-32072,"message":"\#(Self.message)",\#
                "data":{"acpxCode":"PERMISSION_PROMPT_UNAVAILABLE","origin":"cli","sessionId":"unknown"}}}

                """#))
        }
    }

    /// `exec`: acpx's top-level handler prints it bare on stderr.
    @Test func execReportsItOnStderr() {
        var err: [String] = []
        let renderer = OutputRenderer(options: RenderOptions(format: .text), out: { _ in }, err: { _ in }, color: false)
        let code = ExecCommand.reportFailure(ExecCommand.PromptUnavailable(), renderer: renderer, format: "text") {
            err.append($0)
        }
        #expect(err == [Self.message])
        #expect(code == ExitCodes.permissionDenied)
    }
}
