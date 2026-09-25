@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// `exec` bounds each step by `--timeout` and sends a failed prompt again under
/// `--prompt-retries`, as acpx 0.19.1's `runOnce` does (#106). Each expected output is
/// what acpx printed for the same agent (`Fixtures/retry-agent.py`).
struct ExecTimeoutRetryTests {
    struct Run {
        var out: String
        var err: String
        var code: Int32
        /// How many prompts the agent was sent.
        var attempts: Int
        /// The agent's process, which should be gone once `exec` returns.
        var pid: pid_t?
    }

    /// Run `exec` against the fixture agent in `mode`: `options` go before `exec`,
    /// `execOptions` after it.
    private func exec(
        _ mode: String, _ options: [String], execOptions: [String] = [], format: String = "text"
    ) async throws -> Run {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-agent.py")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "notes\n".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let attempts = dir.appendingPathComponent("attempts")
        let pidFile = dir.appendingPathComponent("pid")
        let agent = "/usr/bin/env RETRY_AGENT_MODE=\(mode) RETRY_AGENT_ATTEMPTS='\(attempts.path)' "
            + "RETRY_AGENT_PID='\(pidFile.path)' '\(python)' '\(fixture.path)'"
        let arguments = ["--format", format, "--cwd", dir.path, "--agent", agent] + options
            + ["exec"] + execOptions + ["hi"]
        return await withIsolatedStore {
            let capture = Console.Capture()
            let code = Console.$capture.withValue(capture) { runCommandLine(arguments) }
            let prompts = (try? String(contentsOf: attempts, encoding: .utf8))?.split(separator: "\n").count ?? 0
            let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0) }
            return Run(out: capture.out, err: capture.err, code: code, attempts: prompts, pid: pid)
        }
    }

    private func isRunning(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return kill(pid, 0) == 0
    }

    /// A step of `exec` the fixture holds up, and the last thing text output shows then.
    struct Step: Sendable, CustomTestStringConvertible {
        var mode: String
        var options: [String] = []
        var execOptions: [String] = []
        var lastLine: String
        var testDescription: String { mode }
    }

    private static let timeoutHint =
        "hint: increase `--timeout <seconds>` for long-running prompts, or check whether the agent/provider is stalled."

    // MARK: Timeouts

    /// Each step — starting the agent, `session/new`, the model, each config option, the
    /// prompt — has `--timeout` to itself, and one that runs over fails the run as
    /// `TIMEOUT` (exit 3). The agent is put down by the time `exec` returns, as acpx closes
    /// the client it started — even when it never finished starting.
    @Test(.enabled(if: mockPythonAvailable), arguments: [
        Step(mode: "hang-init", lastLine: "[client] initialize (running)"),
        Step(mode: "hang-new", lastLine: "[client] session/new (running)"),
        Step(mode: "hang-model", options: ["--model", "b"], lastLine: "[client] session/set_config_option (running)"),
        Step(mode: "hang-effort", execOptions: ["--config-option", "effort=high"],
             lastLine: "[client] session/set_config_option (running)"),
        Step(mode: "hang-prompt", lastLine: "[client] session/new (running)")
    ])
    func aStepThatRunsOverTimesOut(step: Step) async throws {
        let run = try await exec(step.mode, ["--timeout", "0.2"] + step.options, execOptions: step.execOptions)
        let mode = step.mode, lastLine = step.lastLine + "\n"
        #expect(run.code == 3)
        #expect(run.err == "Timed out after 200ms\n\(Self.timeoutHint)\n")
        #expect(run.out.hasSuffix(lastLine), "\(run.out)")
        #expect(run.attempts == (mode == "hang-prompt" ? 1 : 0))
        #expect(!isRunning(run.pid), "the agent outlived exec")
    }

    /// A timeout is reported in each format as acpx reports it, and never retried.
    @Test(.enabled(if: mockPythonAvailable))
    func aTimeoutIsReportedInEachFormatAndNotRetried() async throws {
        let options = ["--timeout", "0.2", "--prompt-retries", "2"]
        let json = try await exec("hang-prompt", options, format: "json")
        #expect(json.code == 3)
        #expect(json.out.hasSuffix(#"""
            {"jsonrpc":"2.0","id":null,"error":{"code":-32070,"message":"Timed out after 200ms",\#
            "data":{"acpxCode":"TIMEOUT","origin":"cli","sessionId":"unknown"}}}

            """#))
        #expect(json.err.isEmpty)
        let quiet = try await exec("hang-prompt", options, format: "quiet")
        #expect(quiet.code == 3)
        #expect(quiet.err == "[acpx] error: TIMEOUT Timed out after 200ms\n")
        #expect(quiet.attempts == 1)
    }

    // MARK: Retries

    /// A prompt the agent failed with its internal error, having done nothing yet, goes
    /// again after acpx's pause, with its notice on stderr — none in quiet output. Text
    /// output shows the failed attempt's error where it came.
    @Test(.enabled(if: mockPythonAvailable))
    func aPromptThatFailedWithoutEffectIsRetried() async throws {
        let text = try await exec("fail-once", ["--prompt-retries", "2"])
        #expect(text.code == 0)
        #expect(text.attempts == 2)
        #expect(text.out.hasSuffix("\n[error] RUNTIME: model overloaded\nhello\n\n[done] end_turn\n"), "\(text.out)")
        #expect(text.err == "[acpx] prompt failed (Internal error), retrying in 1000ms (attempt 1/2)\n")
        let quiet = try await exec("fail-once", ["--prompt-retries", "2"], format: "quiet")
        #expect(quiet.code == 0)
        #expect(quiet.out == "hello\n")
        #expect(quiet.err.isEmpty)
    }

    /// Retries stop at the count, and the last attempt's failure is the run's — shown
    /// once in text output, like each attempt's before it.
    @Test(.enabled(if: mockPythonAvailable))
    func retriesStopAtTheirCount() async throws {
        let run = try await exec("fail-always", ["--prompt-retries", "1"])
        #expect(run.code == 1)
        #expect(run.attempts == 2)
        #expect(run.out.hasSuffix(
            "\n[error] RUNTIME: model overloaded\n\n[error] RUNTIME: model overloaded\n"), "\(run.out)")
        #expect(run.out.components(separatedBy: "[error]").count == 3)
        #expect(run.err == "[acpx] prompt failed (Internal error), retrying in 1000ms (attempt 1/1)\n")
    }

    /// A prompt that already had an effect — an update, a file the client read — is not
    /// sent again; nor is one the agent failed with an error that is not passing.
    @Test(.enabled(if: mockPythonAvailable), arguments: ["fail-after-update", "fail-after-read", "fail-auth-once"])
    func aPromptWithAnEffectOrALastingErrorIsNotRetried(mode: String) async throws {
        let run = try await exec(mode, ["--prompt-retries", "2"])
        #expect(run.code == 1)
        #expect(run.attempts == 1)
        #expect(run.err.isEmpty, "\(run.err)")
    }

    /// An update that comes during the pause calls the retry off: the notice has gone
    /// out, but the prompt is not sent again.
    @Test(.enabled(if: mockPythonAvailable))
    func anUpdateDuringThePauseCallsTheRetryOff() async throws {
        let run = try await exec("fail-then-update", ["--prompt-retries", "2"])
        #expect(run.code == 1)
        #expect(run.attempts == 1)
        #expect(run.err == "[acpx] prompt failed (Internal error), retrying in 1000ms (attempt 1/2)\n")
    }

    /// Neither a read the client refused for its path — acpx refuses it before reporting
    /// the operation — nor a permission question is an effect. The permission refused in
    /// the failed attempt still counts at the end, as acpx's client counts every attempt's.
    @Test(.enabled(if: mockPythonAvailable),
          arguments: [("fail-after-bad-read", Int32(0)), ("fail-after-permission", 5)])
    func aRefusedReadOrAPermissionQuestionIsNoEffect(mode: String, code: Int32) async throws {
        // `--deny-all` answers the question without asking at a terminal the tests may have.
        let run = try await exec(mode, ["--prompt-retries", "1", "--deny-all"])
        #expect(run.code == code)
        #expect(run.attempts == 2)
        #expect(run.err == "[acpx] prompt failed (Internal error), retrying in 1000ms (attempt 1/1)\n")
    }

    /// Quiet output shows what the agent said before its prompt failed, then the error.
    @Test(.enabled(if: mockPythonAvailable))
    func quietOutputShowsWhatCameBeforeTheFailure() async throws {
        let run = try await exec("fail-after-update", [], format: "quiet")
        #expect(run.code == 1)
        #expect(run.out == "partial \n")
        #expect(run.err == "[acpx] error: RUNTIME model overloaded\n")
    }

    /// A prompt that needed a permission question nobody could be asked fails as that —
    /// in place of the agent's error, with its details — and is not retried (acpx's
    /// client throws its `PermissionPromptUnavailableError` then). Needs no terminal to
    /// ask at, as in CI.
    @Test(.enabled(if: mockPythonAvailable && !(isatty(0) != 0 && isatty(2) != 0)))
    func aPromptThatCouldNotAskFailsAsThatAndIsNotRetried() async throws {
        let options = ["--prompt-retries", "1", "--non-interactive-permissions", "fail"]
        let text = try await exec("fail-after-permission", options)
        #expect(text.code == 5)
        #expect(text.attempts == 1)
        #expect(text.out.hasSuffix("\n[error] RUNTIME: model overloaded\n"), "\(text.out)")
        #expect(text.err.isEmpty, "\(text.err)")
        let quiet = try await exec("fail-after-permission", options, format: "quiet")
        #expect(quiet.code == 5)
        #expect(quiet.err == "[acpx] error: PERMISSION_PROMPT_UNAVAILABLE model overloaded\n")
        let json = try await exec("fail-after-permission", options, format: "json")
        #expect(json.code == 5)
        #expect(!json.out.contains("acpxCode"), "\(json.out)")
    }

    /// A failed turn hands on every update the agent sent before failing, and only then
    /// throws — so what reports the failure comes after them.
    @Test(.enabled(if: mockPythonAvailable))
    func aFailedTurnHandsOnItsUpdatesBeforeItThrows() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-agent.py")
        var environment = ProcessInfo.processInfo.environment
        environment["RETRY_AGENT_MODE"] = "fail-after-updates"
        let agent = try await ACPAgent.launch(
            agent: "'\(python)' '\(fixture.path)'", cwd: NSTemporaryDirectory(), permission: .approveAll,
            environment: environment, inheritStderr: false)
        let seen = Counter()
        do {
            let response = try await agent.connection.newSession(
                NewSessionRequest(cwd: NSTemporaryDirectory(), mcpServers: []))
            let session = ACPSession(id: response.sessionId, agent: agent)
            await #expect(throws: JSONRPCErrorBody.self) {
                try await session.run([.text("hi")]) { _ in
                    // Slower than the agent: the updates are still coming when it fails.
                    usleep(5_000)
                    seen.add()
                }
            }
        } catch {
            await agent.close()
            throw error
        }
        await agent.close()
        #expect(seen.value == 20)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    // MARK: Parts

    @Test func onlyTheAgentsInternalAndParseErrorsAreRetryable() {
        #expect(PromptRetry.isRetryable(JSONRPCErrorBody(code: -32603, message: "Internal error")))
        #expect(PromptRetry.isRetryable(JSONRPCErrorBody(code: -32700, message: "Parse error")))
        for code in [-32000, -32001, -32002, -32600, -32601, -32602, -32800] {
            #expect(!PromptRetry.isRetryable(JSONRPCErrorBody(code: code, message: "x")), "\(code)")
        }
        #expect(!PromptRetry.isRetryable(TimeoutError(milliseconds: 5)))
        #expect(!PromptRetry.isRetryable(CancellationError()))
    }

    /// `min(1000 × 2^attempt, 10000)`, and the notice in acpx's words.
    @Test func thePauseDoublesUpToTenSeconds() {
        #expect((0...6).map(PromptRetry.delayMilliseconds(afterAttempt:)) == [
            1_000, 2_000, 4_000, 8_000, 10_000, 10_000, 10_000
        ])
        #expect(PromptRetry.delayMilliseconds(afterAttempt: 1_000) == 10_000)
        #expect(PromptRetry.notice(
            for: JSONRPCErrorBody(code: -32603, message: "Internal error"), delayMilliseconds: 2_000, retry: 2,
            maxRetries: 3) == "[acpx] prompt failed (Internal error), retrying in 2000ms (attempt 2/3)")
    }

    /// What counts as an effect of the turn, message by message.
    @Test func sideEffectsAreWhatAcpxCounts() throws {
        func effects(_ lines: [(JSONRPCPeer.WireDirection, String)], active: Bool = true) -> Bool {
            let effects = PromptSideEffects()
            if active { effects.begin() }
            for (direction, line) in lines { effects.observe(direction, Data(line.utf8)) }
            return effects.any
        }
        let update = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{}}}"#
        #expect(effects([(.inbound, update)]))
        #expect(!effects([(.inbound, update)], active: false))
        func request(_ method: String) -> (JSONRPCPeer.WireDirection, String) {
            (.inbound, #"{"jsonrpc":"2.0","id":7,"method":"\#(method)","params":{"sessionId":"s"}}"#)
        }
        func refusal(_ details: String, code: Int = -32603) -> (JSONRPCPeer.WireDirection, String) {
            let error = #"{"code":\#(code),"message":"x","data":{"details":"\#(details)"}}"#
            return (.outbound, #"{"jsonrpc":"2.0","id":7,"error":\#(error)}"#)
        }
        let answer = (JSONRPCPeer.WireDirection.outbound, #"{"jsonrpc":"2.0","id":7,"result":{}}"#)
        // A file or terminal request counts once it is taken on, and while it is.
        #expect(effects([request("fs/read_text_file"), answer]))
        #expect(effects([request("fs/write_text_file")]))
        #expect(effects([request("terminal/create"), refusal("Permission denied")]))
        #expect(effects([request("fs/read_text_file"), refusal("ENOENT: no such file")]))
        // Unless it was refused before acpx would report it.
        #expect(!effects([request("fs/read_text_file"), refusal("Path must be absolute: a.txt")]))
        #expect(!effects([request("fs/write_text_file"), refusal("Path is outside allowed cwd subtree: /x")]))
        #expect(!effects([request("fs/read_text_file"), refusal("Method not found", code: -32601)]))
        #expect(!effects([request("terminal/create"), refusal("Invalid params", code: -32602)]))
        #expect(!effects([request("terminal/output"), refusal("Unknown terminal: t1")]))
        #expect(effects([request("terminal/release"), refusal("Unknown terminal: t1")]))
        // A wait for a command's exit counts once it is answered.
        #expect(!effects([request("terminal/wait_for_exit")]))
        #expect(effects([request("terminal/wait_for_exit"), answer]))
        // A permission question is none, nor is any other request or response.
        #expect(!effects([request("session/request_permission"), answer]))
        #expect(!effects([(.inbound, #"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#)]))
        // A permission notice is one.
        let notice = PromptSideEffects()
        notice.begin()
        notice.clientOperation()
        #expect(notice.any)
    }

    /// The prefixes the path refusals are recognized by are the client's own.
    @Test func thePathRefusalsAreTheClientsOwn() {
        #expect(PromptSideEffects.pathRefusals == [
            FileSystemContainment.mustBeAbsolute, FileSystemContainment.outsideCwdSubtree
        ])
    }

    /// acpx's `withTimeout` races the operation: the deadline throws at once, without
    /// waiting for an operation that does not stop when cancelled.
    @Test func aDeadlineDoesNotWaitForTheOperation() async throws {
        #expect(try await withTimeout(milliseconds: 1_000) { 7 } == 7)
        #expect(try await withTimeout(milliseconds: nil) { 8 } == 8)
        #expect(try await withTimeout(milliseconds: 0) { 9 } == 9)
        let gate = Gate()
        await #expect(throws: TimeoutError(milliseconds: 50)) {
            try await withTimeout(milliseconds: 50) { await gate.wait() }
        }
        gate.open()
        #expect(TimeoutError(milliseconds: 50).localizedDescription == "Timed out after 50ms")
    }

    /// A wait that ignores cancellation, until opened.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let waiting = lock.withLock {
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            waiting.forEach { $0.resume() }
        }
    }
}
