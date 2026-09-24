@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// A failure that reaches the top level is reported in the requested output format, as
/// acpx's `emitRequestedError` reports it (#69). Expected lines are acpx 0.19.1's for the
/// same failures.
@Suite struct TopLevelFailureTests {
    /// What reporting produced: stdout, the stderr lines, and the exit code.
    private struct Reported {
        var out: String
        var err: [String]
        var code: Int32
    }

    private static func report(_ error: Error, _ arguments: [String]) -> Reported {
        var out = ""
        var err: [String] = []
        let code = TopLevelFailure.report(
            error, arguments: arguments, out: { out += $0 }, err: { err.append($0) })
        return Reported(out: out, err: err, code: code)
    }

    private static let brokenConfig = ConfigError("Invalid JSON in /p/.acpxrc.json: Unexpected end of JSON input")

    @Test func aBrokenConfigIsReportedInTheRequestedFormat() async {
        let json = Self.report(Self.brokenConfig, ["--format", "json", "sessions", "list"])
        #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Invalid JSON in "#
            + #"/p/.acpxrc.json: Unexpected end of JSON input","data":{"acpxCode":"RUNTIME","origin":"cli","#
            + #""sessionId":"unknown"}}}"# + "\n")
        #expect(json.err.isEmpty)
        #expect(json.code == ExitCodes.error)

        let quiet = Self.report(Self.brokenConfig, ["--format", "quiet", "sessions", "list"])
        #expect(quiet.err == ["[acpx] error: RUNTIME Invalid JSON in /p/.acpxrc.json: Unexpected end of JSON input"])

        // Nothing asked for: the config would say, but it does not load.
        await withIsolatedStore {
            try? Data("{".utf8).write(to: ACPXPaths.globalConfigPath)
            let text = Self.report(Self.brokenConfig, ["sessions", "list"])
            #expect(text.err == ["Invalid JSON in /p/.acpxrc.json: Unexpected end of JSON input"])
            #expect(text.out.isEmpty)
        }
    }

    /// A failure the output already shows is not reported again, in any format — only
    /// its exit code is left to give (acpx's `isOutputAlreadyEmitted`).
    @Test func aFailureTheOutputShowsIsOnlyAnExitCode() {
        for format in ["json", "quiet", "text"] {
            let gone = Self.report(
                FailureAlreadyShown(underlying: NoSessionError("gone")), ["--format", format, "mock", "hi"])
            #expect(gone.out.isEmpty && gone.err.isEmpty, "\(format)")
            #expect(gone.code == ExitCodes.noSession, "\(format)")
        }
        let failed = Self.report(
            FailureAlreadyShown(underlying: JSONRPCErrorBody(code: -32603, message: "Internal error")),
            ["--format", "json", "mock", "hi"])
        #expect(failed.out.isEmpty && failed.err.isEmpty)
        #expect(failed.code == ExitCodes.error)
    }

    /// With no format asked for, a failure is reported in the format of the config
    /// acpx loaded at start-up — from the leading `--cwd`, not a later one.
    @Test func otherwiseTheConfigsFormatDecides() async throws {
        try await withIsolatedStore {
            let cwd = NSTemporaryDirectory() + "acpx-top-level-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            try Data(#"{"format":"quiet"}"#.utf8).write(to: ACPXPaths.projectConfigPath(cwd: cwd))
            #expect(TopLevelFailure.requestedFormat(["--cwd", cwd, "sessions", "show", "nope"]) == "quiet")
            #expect(TopLevelFailure.requestedFormat(["--cwd", cwd, "--format", "json", "sessions"]) == "json")
            #expect(TopLevelFailure.requestedFormat(["sessions", "show", "--cwd", cwd]) == "text")
        }
    }

    /// In text mode every failure gets the hints its message calls for, a command's
    /// own included — acpx gives them to whatever reaches its top-level handler.
    @Test func textModeAddsTheHintsTheMessageCallsFor() async {
        await withIsolatedStore {
            let limited = Self.report(CLIError("agent failed: HTTP 429 Too Many Requests"), ["sessions", "new"])
            #expect(limited.err == [
                "agent failed: HTTP 429 Too Many Requests",
                "hint: the provider appears rate-limited; retry later, switch model, or check provider quota/billing."
            ])
            #expect(limited.code == ExitCodes.error)
        }
    }

    @Test func aMissingSessionIsNoSession() {
        let missing = NoSessionError(
            "⚠ No acpx session found (searched up to /x).\nCreate one: acpx codex sessions new")
        let quiet = Self.report(missing, ["--format", "quiet", "codex", "prompt", "hi"])
        #expect(quiet.err == [
            "[acpx] error: NO_SESSION ⚠ No acpx session found (searched up to /x). Create one: acpx codex sessions new"
        ])
        #expect(quiet.code == ExitCodes.noSession)
        #expect(Self.report(missing, ["--json-strict", "codex", "prompt", "hi"]).out.contains(#""code":-32002"#))
    }

}
