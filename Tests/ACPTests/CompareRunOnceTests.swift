@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// `compare` runs each agent as acpx 0.19.1's `runOnce` does (#102): within `--timeout`,
/// under `--prompt-retries`, with the invocation's session options. Each row keeps what
/// the agent said, the usage it reported and an error's own message. A signal puts the
/// agent running down, admits no other, and ends `compare` `INTERRUPTED` (130).
struct CompareRunOnceTests {
    struct Compared {
        var code: Int32
        var rows: [[String: Any]]
    }

    /// `compare` in JSON over a `retry-agent.py` in each of `modes`. The signal comes as
    /// the agent at `interrupting` gets its prompt.
    private func compare(
        _ modes: [String], _ options: [String] = [], interrupting: Int? = nil
    ) async throws -> Compared {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-agent.py")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready")
        let source = Interrupts.Source()
        let watch = interrupting == nil ? nil : try ExecInterruptTests.fire(source, whenWrittenTo: ready)
        defer { watch?.cancel() }
        let agents = modes.enumerated().map { index, mode in
            "/usr/bin/env RETRY_AGENT_MODE=\(mode) RETRY_AGENT_ATTEMPTS='\(dir.path)/attempts-\(index)' "
                + (index == interrupting ? "RETRY_AGENT_READY='\(ready.path)' " : "") + "'\(python)' '\(fixture.path)'"
        }
        let arguments = ["--format", "json", "--cwd", dir.path, "--approve-all"] + options
            + ["compare"] + agents + ["hi"]
        let (code, out) = await withIsolatedStore {
            let capture = Console.Capture()
            // `compare` blocks its thread until it is done, as the CLI does: a thread of its own.
            let code: Int32 = await withCheckedContinuation { continuation in
                Thread {
                    let code = Console.$capture.withValue(capture) {
                        Interrupts.$source.withValue(source) { runCommandLine(arguments) }
                    }
                    continuation.resume(returning: code)
                }.start()
            }
            return (code, capture.out)
        }
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]])
        return Compared(code: code, rows: rows)
    }

    /// From the agent's `usage_update`, `_meta.usage` in snake or camel case.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aRowCarriesTheUsageTheAgentReported() async throws {
        let compared = try await compare(["usage-meta"])
        let row = try #require(compared.rows.first)
        #expect(compared.code == ExitCodes.success)
        #expect(row["input_tokens"] as? Int == 7)
        #expect(row["output_tokens"] as? Int == 8)
        #expect(row["total_tokens"] as? Int == 15)
        #expect(row["final_message"] as? String == "hello")
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aRunPastTheTimeoutIsACancelledRow() async throws {
        let compared = try await compare(["hang-prompt", "ok"], ["--timeout", "0.3"])
        #expect(compared.code == ExitCodes.timeout)
        let row = try #require(compared.rows.first)
        #expect(row["status"] as? String == "cancelled")
        #expect(row["stop_reason"] is NSNull)
        #expect(row["error"] as? String == "Timed out after 300ms")
        #expect(compared.rows.last?["status"] as? String == "ok")
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aFailureIsRetriedUnderPromptRetries() async throws {
        let compared = try await compare(["fail-once"], ["--prompt-retries", "1"])
        #expect(compared.code == ExitCodes.success)
        #expect(compared.rows.first?["status"] as? String == "ok")
        #expect(compared.rows.first?["final_message"] as? String == "hello")
    }

    /// acpx's `buildErrorRow`: the text so far, and the error's own message.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anErrorRowKeepsWhatTheAgentSaidAndTheErrorsMessage() async throws {
        let compared = try await compare(["fail-after-update"])
        #expect(compared.code == ExitCodes.error)
        let row = try #require(compared.rows.first)
        #expect(row["status"] as? String == "error")
        #expect(row["final_message"] as? String == "partial")
        #expect(row["error"] as? String == "Internal error")
    }

    /// The invocation's session options go to each session: a `--model` the agent does
    /// not offer fails its row, as acpx's does.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func eachSessionTakesTheInvocationsModel() async throws {
        let compared = try await compare(["ok"], ["--model", "zzz"])
        let row = try #require(compared.rows.first)
        #expect(row["status"] as? String == "error")
        #expect(row["error"] as? String
            == #"Cannot apply --model "zzz": the ACP agent did not advertise that model. Available models: a, b."#)
    }

    /// The agent the signal comes during answers the cancel, and its row says it was
    /// interrupted; the next agent never runs.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSignalPutsTheAgentRunningDownAndAdmitsNoOther() async throws {
        let compared = try await compare(["stall-prompt", "ok"], interrupting: 0)
        #expect(compared.code == ExitCodes.interrupted)
        #expect(compared.rows.count == 1)
        let row = try #require(compared.rows.first)
        #expect(row["status"] as? String == "cancelled")
        #expect(row["stop_reason"] as? String == "cancelled")
        #expect(row["error"] as? String == "Interrupted")
    }

    /// `compare` hears a signal during a later agent too, after an earlier agent's run
    /// has stopped listening for its own.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSignalDuringALaterAgentIsHeard() async throws {
        let compared = try await compare(["ok", "stall-prompt", "ok"], interrupting: 1)
        #expect(compared.code == ExitCodes.interrupted)
        #expect(compared.rows.map { $0["status"] as? String } == ["ok", "cancelled"])
        #expect(compared.rows.last?["error"] as? String == "Interrupted")
    }

    /// A signal that comes once `compare` admitted an agent, but before the agent's run
    /// listens for one, still puts that run down: Node dispatches none between the two,
    /// so acpx's run always hears it.
    @Test(.timeLimit(.minutes(1)))
    func aSignalBeforeTheRunListensStillPutsItDown() {
        let source = Interrupts.Source()
        let (rows, interrupted) = Interrupts.$source.withValue(source) {
            CompareCommand.runAgents(["agent"]) { name in
                source.fire()
                let ran = (try? runBlocking {
                    try await Interrupts.withInterrupt({
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        return "ran on"
                    }, onInterrupt: { $0() })
                }) ?? "put down"
                return CompareCommand.Row(
                    agent: name, status: "ok", stopReason: nil, wallMs: 0, finalMessage: ran, error: nil)
            }
        }
        #expect(interrupted)
        #expect(rows.map(\.finalMessage) == ["put down"])
        #expect(rows.map(\.error) == ["Interrupted"])
    }
}
