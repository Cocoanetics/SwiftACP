@testable import ACPXCore
@testable import acpx
import Dispatch
import Foundation
import SwiftACP
import Testing

/// `exec` interrupted, as acpx 0.19.1's `runOnce` is (`withInterrupt`, #147): at the first
/// SIGINT, SIGTERM or SIGHUP the prompt out is cancelled and given 2.5 s, then the agent
/// is closed; unless the run ended by then, it exits `INTERRUPTED` (130) without a word.
/// Each expected output is what acpx printed for the same agent (`Fixtures/retry-agent.py`),
/// 0.19.3 for an agent gone with the prompt out.
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
    /// prompt, which ends the run reported, once, as acpx 0.19.3 reports an agent gone with
    /// the prompt out (#778). Which of the connection's end and its close fails the prompt
    /// first decides SwiftACP's words. acpx's are always `ACP agent disconnected during
    /// request (process_exit, exit=null, signal=SIGTERM)`, as it ends the agent's process
    /// before it closes the connection, which #142 tracks.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anAgentThatDoesNotAnswerIsClosed() async throws {
        let run = try await exec("hang-prompt")
        #expect(run.code == 1)
        #expect(run.out == "[client] initialize (running)\n\n[client] session/new (running)\n")
        #expect(run.err == "ACP connection closed\n" || run.err.hasPrefix("ACP agent disconnected during request ("),
                "\(run.err)")
        #expect(run.err.components(separatedBy: "\n").count == 2, "\(run.err)")
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

    /// While the session is being opened, the close fails `session/new`, and the run ends
    /// on that — reported, exit 1, as acpx reports the agent's disconnect then. (Which of
    /// the transport's end and the connection's close fails it first decides the words;
    /// acpx's are `ACP agent disconnected during request (process_exit, exit=null,
    /// signal=SIGTERM)`, the end as #142 would record it.)
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anInterruptWhileTheSessionOpensEndsTheRunOnItsFailure() async throws {
        let run = try await exec("hang-new")
        #expect(run.code == 1)
        #expect(!run.err.isEmpty)
        #expect(!isRunning(run.pid))
    }

    /// An agent gone before any prompt went out is reported, as acpx reports it: the
    /// connection closed, in its SDK's words. Should the prompt beat the agent's exit onto
    /// the wire, the run is the agent's disconnect instead, reported just as once (#778);
    /// which comes first is up to the two processes, in acpx as here. One run a case: the
    /// time limit counts the wait for the store, which a second run would queue for again.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: ["text", "quiet"])
    func anAgentGoneBeforeThePromptIsReported(format: String) async throws {
        let disconnect = "ACP agent disconnected during request (process_exit, exit=3, signal=null)"
        let run = try await exec("die-after-new", format: format, interrupting: false)
        #expect(run.code == 1)
        let reported = format == "text" ? ["ACP connection closed\n", disconnect + "\n"] : [
            "[acpx] error: RUNTIME ACP connection closed\n", "[acpx] error: RUNTIME AGENT_DISCONNECTED \(disconnect)\n"
        ]
        #expect(reported.contains(run.err), "\(run.err)")
    }

    /// An agent that goes with the prompt out ends the run reported once, in any format,
    /// after what it said: acpx 0.19.3 marks an error shown only when the output shows the
    /// agent's error (`markOutputAlreadyEmitted`, #778), where 0.19.1 showed nothing.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: ["text", "quiet", "json"])
    func anAgentGoneWithThePromptOutIsReportedOnce(format: String) async throws {
        let run = try await exec("die-in-prompt", format: format, interrupting: false)
        let disconnect = "ACP agent disconnected during request (process_exit, exit=3, signal=null)"
        #expect(run.code == 1)
        #expect((run.out + run.err).components(separatedBy: disconnect).count == 2, "\(run.out)\(run.err)")
        switch format {
        case "text":
            #expect(run.out.hasSuffix("[client] session/new (running)\npartial \n"), "\(run.out)")
            #expect(run.err == disconnect + "\n")
        case "quiet":
            #expect(run.out == "partial \n")
            #expect(run.err == "[acpx] error: RUNTIME AGENT_DISCONNECTED \(disconnect)\n")
        default:
            #expect(run.err.isEmpty)
            #expect(run.out.hasSuffix(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":""#
                + disconnect + #"","data":{"acpxCode":"RUNTIME","detailCode":"AGENT_DISCONNECTED","origin":"acp","#
                + #""sessionId":"unknown"}}}"# + "\n"), "\(run.out)")
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
    static func fire(
        _ source: Interrupts.Source, whenWrittenTo path: URL, signal: String = "SIGINT"
    ) throws -> DispatchSourceRead {
        guard mkfifo(path.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let fd = open(path.path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        reader.setEventHandler {
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) > 0 else { return }
            reader.cancel()
            source.fire(signal)
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
