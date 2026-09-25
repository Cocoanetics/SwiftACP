@testable import ACPXCore
@testable import acpx
import Dispatch
import Foundation
import SwiftACP
import Testing

/// `exec` interrupted, as acpx 0.19.1's `runOnce` is (`withInterrupt`, #147): at the first
/// SIGINT, SIGTERM or SIGHUP the prompt out is cancelled and given 2.5 s, then the agent
/// is closed; unless the run ended by then, it exits `INTERRUPTED` (130) without a word.
/// Each expected output is what acpx printed for the same agent (`Fixtures/retry-agent.py`).
/// A signal is stood in for by ``Interrupts/Source``, fired as the agent gets its prompt.
struct ExecInterruptTests {
    struct Run {
        var out: String
        var err: String
        var code: Int32
        var attempts: Int
        var pid: pid_t?
    }

    /// An agent that answers the cancelled prompt ends the run as it answered.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPromptTheAgentAnswersCancelledEndsTheRunSo() async throws {
        let run = try await exec("stall-prompt")
        #expect(run.code == 0, "\(run.code) \(run.err)")
        #expect(run.out == "[client] initialize (running)\n\n[client] session/new (running)\n\n[done] cancelled\n")
        #expect(run.err.isEmpty)
        #expect(!isRunning(run.pid))
    }

    /// An agent that does not answer is closed once 2.5 s have passed. That fails the
    /// prompt, which ends the run — with nothing shown for it, as acpx shows nothing for
    /// an agent gone with the prompt out.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anAgentThatDoesNotAnswerIsClosed() async throws {
        let run = try await exec("hang-prompt")
        #expect(run.code == 1)
        #expect(run.out == "[client] initialize (running)\n\n[client] session/new (running)\n")
        #expect(run.err.isEmpty, "\(run.err)")
        #expect(!isRunning(run.pid))
    }

    /// With nothing out — in the pause before a retry — the run ends as interrupted.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aRunInThePauseBeforeARetryEndsInterrupted() async throws {
        let run = try await exec("fail-once", ["--prompt-retries", "1"])
        #expect(run.code == ExitCodes.interrupted)
        #expect(run.attempts == 1)
        #expect(run.out.hasSuffix("[error] RUNTIME: model overloaded\n"), "\(run.out)")
        #expect(!isRunning(run.pid))
    }

    /// An agent that goes with the prompt out ends the run with nothing more shown, in any
    /// format: acpx's error carries `outputAlreadyEmitted`.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: ["text", "quiet", "json"])
    func anAgentGoneWithThePromptOutIsNotReported(format: String) async throws {
        let run = try await exec("die-in-prompt", format: format, interrupting: false)
        #expect(run.code == 1)
        #expect(run.err.isEmpty)
        switch format {
        case "text": #expect(run.out.hasSuffix("[client] session/new (running)\npartial \n"), "\(run.out)")
        case "quiet": #expect(run.out == "partial \n")
        default: #expect(!run.out.contains("\"error\""), "\(run.out)")
        }
    }

    // MARK: - Support

    /// Run `exec` against the fixture agent in `mode`, `options` before `exec` — its
    /// interrupt fired as the agent gets its prompt, unless not `interrupting`.
    private func exec(
        _ mode: String, _ options: [String] = [], format: String = "text", interrupting: Bool = true
    ) async throws -> Run {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-agent.py")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("interrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let attempts = dir.appendingPathComponent("attempts")
        let pidFile = dir.appendingPathComponent("pid")
        let ready = dir.appendingPathComponent("ready")
        let source = Interrupts.Source()
        let watch = interrupting ? try Self.fire(source, whenWrittenTo: ready) : nil
        defer { watch?.cancel() }
        let agent = "/usr/bin/env RETRY_AGENT_MODE=\(mode) RETRY_AGENT_ATTEMPTS='\(attempts.path)' "
            + "RETRY_AGENT_PID='\(pidFile.path)' "
            + (interrupting ? "RETRY_AGENT_READY='\(ready.path)' " : "")
            + "'\(python)' '\(fixture.path)'"
        let arguments = ["--format", format, "--cwd", dir.path, "--agent", agent] + options + ["exec", "hi"]
        return await withIsolatedStore {
            let capture = Console.Capture()
            // `exec` blocks its thread until it is done, as the CLI does: a thread of its own.
            let code: Int32 = await withCheckedContinuation { continuation in
                Thread {
                    let code = Console.$capture.withValue(capture) {
                        Interrupts.$source.withValue(interrupting ? source : nil) { runCommandLine(arguments) }
                    }
                    continuation.resume(returning: code)
                }.start()
            }
            let prompts = (try? String(contentsOf: attempts, encoding: .utf8))?.split(separator: "\n").count ?? 0
            let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0) }
            return Run(out: capture.out, err: capture.err, code: code, attempts: prompts, pid: pid)
        }
    }

    /// Fire `source` when something is written to the FIFO at `path`, which this makes.
    /// Opened for reading and writing, so that neither side waits for the other and no
    /// end of it is seen while the agent has yet to open it.
    private static func fire(_ source: Interrupts.Source, whenWrittenTo path: URL) throws -> DispatchSourceRead {
        guard mkfifo(path.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let fd = open(path.path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        reader.setEventHandler {
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) > 0 else { return }
            reader.cancel()
            source.fire()
        }
        reader.setCancelHandler { close(fd) }
        reader.resume()
        return reader
    }

    private func isRunning(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return kill(pid, 0) == 0
    }
}
