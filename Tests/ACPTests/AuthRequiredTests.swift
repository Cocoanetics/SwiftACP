@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// A failure that needs credentials is reported as acpx 0.19.1 reports it (#132): by its
/// own message, with the `AUTH_REQUIRED` detail code, and a hint naming the `auth` keys to
/// add. Expected lines are acpx's for the same agents.
struct AuthRequiredTests {
    static let policyMessage = "agent advertised auth methods [probe-login] but no matching credentials found"
    static let policyHint =
        "hint: run `acpx config show` to locate the active config, then add `auth.probe-login` and retry."
    static let genericHint = "hint: run `acpx config show` to locate the active config, then add the required "
        + "credential under `auth` and retry."

    // MARK: Classing

    /// acpx's `isAcpAuthRequiredPayload`: `-32000`, saying so in the message, or in the
    /// data by `authRequired: true`, a `methodId`, or some `methods`.
    @Test func anAgentsErrorSaysItNeedsCredentialsAsAcpxReadsIt() {
        func says(_ code: Double, _ message: String, _ data: String? = nil) -> Bool {
            AcpErrorPayload(code: code, message: message, data: data.flatMap { WireJSON(parsing: $0) })
                .saysAuthRequired
        }
        #expect(says(-32000, "Authentication required"))
        #expect(says(-32000, "LOGIN REQUIRED to go on"))
        #expect(says(-32000, "a token required here"))
        #expect(!says(-32603, "Authentication required"))
        #expect(!says(-32000, "Internal error"))
        #expect(says(-32000, "Internal error", #"{"authRequired":true}"#))
        #expect(!says(-32000, "Internal error", #"{"authRequired":"true"}"#))
        #expect(says(-32000, "Internal error", #"{"methodId":"x"}"#))
        #expect(!says(-32000, "Internal error", #"{"methodId":" \n"}"#))
        #expect(says(-32000, "Internal error", #"{"methods":[1]}"#))
        #expect(!says(-32000, "Internal error", #"{"methods":[]}"#))
        #expect(!says(-32000, "Internal error", #"[{"authRequired":true}]"#))
    }

    // MARK: The hint

    /// acpx's `renderAuthRequiredHint`: the methods the error's data names, then those its
    /// message names, each once, as `auth.<id>` keys — or the credential in general.
    @Test func theHintNamesTheAuthKeysTheFailureNames() {
        func hint(_ message: String, _ data: String? = nil) -> [String] {
            let acp = data.map { AcpErrorPayload(code: -32000, message: message, data: WireJSON(parsing: $0)) }
            return remediationHints(
                code: "RUNTIME", origin: "acp", detailCode: "AUTH_REQUIRED", message: message, acp: acp)
        }
        #expect(hint(Self.policyMessage) == [Self.policyHint])
        #expect(hint("Authentication required") == [Self.genericHint])
        #expect(hint("agent advertised Auth Methods [a, b ,, ] but none")
            == ["hint: run `acpx config show` to locate the active config, then add `auth.a` or `auth.b` and retry."])
        #expect(hint("needs auth method z", #"{"methodId":" x ","methods":[{"id":"y"},"x"," ",3,["w"]]}"#)
            == ["hint: run `acpx config show` to locate the active config, then add `auth.x`, `auth.y`, or "
                + "`auth.z` and retry."])
        // No other detail code gets it.
        #expect(remediationHints(
            code: "RUNTIME", origin: "cli", detailCode: nil, message: Self.policyMessage, acp: nil).isEmpty)
    }

    // MARK: The top level

    /// What was printed — stdout, and stderr as lines — and the exit code.
    private struct Reported {
        var out: String
        var err: [String]
        var code: Int32
    }

    /// What the top level reported of `error` in `format`.
    private static func report(_ error: Error, format: String) -> Reported {
        var out = ""
        var err: [String] = []
        let code = TopLevelFailure.report(
            error, arguments: ["--format", format, "sessions", "new"], out: { out += $0 }, err: { err.append($0) })
        return Reported(out: out, err: err, code: code)
    }

    /// `--auth-policy fail` with no credential for the agent's method, as acpx reports its
    /// `AuthPolicyError`.
    @Test func anUnmatchedAuthMethodIsReportedAsAcpxReportsIt() {
        let error = AuthPolicyError(methodIds: ["probe-login"])
        let text = Self.report(error, format: "text")
        #expect(text.err == [Self.policyMessage, Self.policyHint] && text.out.isEmpty && text.code == 1)
        let json = Self.report(error, format: "json")
        #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"\#(Self.policyMessage)","#
            + #""data":{"acpxCode":"RUNTIME","detailCode":"AUTH_REQUIRED","origin":"acp","sessionId":"unknown"}}}"#
            + "\n")
        let quiet = Self.report(error, format: "quiet")
        #expect(quiet.err == ["[acpx] error: RUNTIME AUTH_REQUIRED \(Self.policyMessage)"])
    }

    /// The agent's `-32000` error at the top level: its message, its code and data in the
    /// JSON line, its details in quiet output, and the hint for the method it names.
    @Test func anAgentsAuthErrorIsReportedAsAcpxReportsIt() {
        let error = JSONRPCErrorBody(
            code: -32000, message: "Authentication required",
            data: .object(["details": .string("login first"), "methodId": .string("probe-login")]))
        let text = Self.report(error, format: "text")
        #expect(text.err == [
            "Authentication required",
            "hint: run `acpx config show` to locate the active config, then add `auth.probe-login` and retry."
        ])
        let json = Self.report(error, format: "json")
        #expect(json.out == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Authentication required","#
            + #""data":{"acpxCode":"RUNTIME","detailCode":"AUTH_REQUIRED","origin":"cli","sessionId":"unknown","#
            + #""details":"login first","methodId":"probe-login"}}}"# + "\n")
        let quiet = Self.report(error, format: "quiet")
        #expect(quiet.err == ["[acpx] error: RUNTIME AUTH_REQUIRED login first"])
        #expect(text.code == 1 && json.code == 1 && quiet.code == 1)
    }

    // MARK: End to end

    /// Run the CLI on the mock agent with `environment`, on a thread of its own: it blocks
    /// its thread until done, which the tasks' pool must not lose.
    private static func run(_ arguments: [String], environment: [String] = []) async throws -> Ran {
        let command = try #require(mockCommand())
        let agent = (environment.isEmpty ? "" : "/usr/bin/env " + environment.joined(separator: " ") + " ") + command
        return await withIsolatedStore {
            let capture = Console.Capture()
            let code: Int32 = await withCheckedContinuation { continuation in
                Thread {
                    continuation.resume(returning: Console.$capture.withValue(capture) {
                        runCommandLine(["--agent", agent] + arguments)
                    })
                }.start()
            }
            return Ran(out: capture.out, err: capture.err, code: code)
        }
    }

    /// What a run printed, and its exit code.
    private struct Ran {
        var out: String
        var err: String
        var code: Int32
    }

    /// `exec` under `--auth-policy fail`, the agent advertising a method nothing matches.
    @Test(.enabled(if: mockPythonAvailable))
    func execFailsOnAnUnmatchedAuthMethod() async throws {
        let options = ["--auth-policy", "fail"]
        let text = try await Self.run(options + ["exec", "hi"], environment: ["MOCK_AUTH_METHODS=probe-login"])
        #expect(text.err == Self.policyMessage + "\n" + Self.policyHint + "\n")
        #expect(text.code == 1)
        let quiet = try await Self.run(
            ["--format", "quiet"] + options + ["exec", "hi"], environment: ["MOCK_AUTH_METHODS=probe-login"])
        #expect(quiet.err == "[acpx] error: RUNTIME AUTH_REQUIRED \(Self.policyMessage)\n")
        let json = try await Self.run(
            ["--format", "json"] + options + ["exec", "hi"], environment: ["MOCK_AUTH_METHODS=probe-login"])
        #expect(json.out.hasSuffix(#""data":{"acpxCode":"RUNTIME","detailCode":"AUTH_REQUIRED","origin":"acp","#
            + #""sessionId":"unknown"}}}"# + "\n"), "\(json.out)")
    }

    /// A prompt the agent fails with its `-32000` auth error: quiet output classes it.
    @Test(.enabled(if: mockPythonAvailable))
    func execClassesTheAgentsAuthError() async throws {
        let quiet = try await Self.run(["--format", "quiet", "exec", "auth turn"])
        #expect(quiet.err == "[acpx] error: RUNTIME AUTH_REQUIRED login first\n")
        #expect(quiet.code == 1)
    }

    /// `sessions new` hands the agent's error to the top level as it is.
    @Test(.enabled(if: mockPythonAvailable))
    func sessionsNewReportsTheAgentsAuthError() async throws {
        let error = #"'{"code":-32000,"message":"Authentication required","data":{"details":"login first"}}'"#
        let quiet = try await Self.run(
            ["--format", "quiet", "sessions", "new"], environment: ["MOCK_NEW_ERROR=\(error)"])
        #expect(quiet.err == "[acpx] error: RUNTIME AUTH_REQUIRED login first\n")
        #expect(quiet.code == 1)
        let text = try await Self.run(["sessions", "new"], environment: ["MOCK_NEW_ERROR=\(error)"])
        #expect(text.err == "Authentication required\n" + Self.genericHint + "\n")
    }
}
