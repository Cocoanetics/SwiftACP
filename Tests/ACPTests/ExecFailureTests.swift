@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// How `exec` reports a failed run in text and quiet modes (#60), as acpx 0.19.1 does:
/// the agent's error response is rendered once, by its details when it gave some; any
/// other failure goes to stderr bare, with its hints; quiet mode says it on one line.
/// Expected lines are acpx's, from running both CLIs against the same agents.
@Suite struct ExecFailureTests {
    private static let detailed = JSONRPCErrorBody(
        code: -32603, message: "Internal error", data: .object(["details": .string("model exploded")]))

    /// What reporting a failure produced: the formatter's stdout, the stderr lines,
    /// and the exit code.
    private struct Reported {
        var out: String
        var err: [String]
        var code: Int32
    }

    private static func report(_ error: Error, _ format: OutputFormat) -> Reported {
        let out = OutputRendererTests.Capture()
        var err: [String] = []
        let renderer = OutputRenderer(
            options: RenderOptions(format: format, streamsWire: true), out: out.write, err: { _ in }, color: false)
        let name = format == .quiet ? "quiet" : format == .json ? "json" : "text"
        let code = ExecCommand.reportFailure(error, renderer: renderer, format: name) { err.append($0) }
        return Reported(out: out.text, err: err, code: code)
    }

    @Test func anAgentErrorIsShownByItsDetailsAndNotRepeated() {
        let reported = Self.report(Self.detailed, .text)
        #expect(reported.out == "[error] RUNTIME: model exploded\n")
        #expect(reported.err.isEmpty)
        #expect(reported.code == ExitCodes.error)
    }

    /// Without details the message is the generic "Internal error", and the hint to
    /// rerun with `--verbose` applies.
    @Test func anAgentErrorWithoutDetailsGetsTheVerboseHint() {
        let reported = Self.report(JSONRPCErrorBody(code: -32603, message: "Internal error"), .text)
        #expect(reported.out == """
            [error] RUNTIME: Internal error
            hint: rerun with `--verbose` to capture the underlying ACP error details.

            """)
        #expect(reported.err.isEmpty)
    }

    @Test func quietModeSaysItOnOneLine() {
        #expect(Self.report(Self.detailed, .quiet).err == ["[acpx] error: RUNTIME model exploded"])
        let spawn = AgentLaunchError(
            agentCommand: "ghost", workingDirectory: nil, detailCode: AgentLaunchError.spawnENOENT)
        let line = Self.report(spawn, .quiet).err.first
        #expect(line?.hasPrefix(
            "[acpx] error: RUNTIME AGENT_SPAWN_ENOENT Failed to spawn agent command: ghost.") == true)
        let multiLine = JSONRPCErrorBody(code: -32603, message: "one\r\ntwo\nthree")
        #expect(Self.report(multiLine, .quiet).err == ["[acpx] error: RUNTIME one two three"])
    }

    /// A failure that never reached the stream goes to stderr as it is — no
    /// `error:` prefix, which acpx keeps for usage errors.
    @Test func aFailureOffTheWireGoesToStderrBare() {
        let spawn = AgentLaunchError(agentCommand: "ghost", workingDirectory: nil, detailCode: nil)
        let reported = Self.report(spawn, .text)
        #expect(reported.out.isEmpty)
        #expect(reported.err == ["Failed to spawn agent command: ghost"])
        #expect(reported.code == ExitCodes.error)
    }

    /// acpx's `resolveOutputErrorCode`: a runtime failure saying the session is gone is
    /// `NO_SESSION`, exit 4.
    @Test func aGoneSessionExitsWithNoSession() {
        let gone = JSONRPCErrorBody(code: -32002, message: "Resource not found: session s-1")
        #expect(Self.report(gone, .text).code == ExitCodes.noSession)
        #expect(Self.report(gone, .quiet).err == ["[acpx] error: NO_SESSION Resource not found: session s-1"])
    }
}
