@testable import ACPXCore
@testable import acpx
import Foundation
import Testing

/// An agent's error answering a control of `exec`'s session setup is shown as acpx shows
/// it: its text formatter shows each error it reads on the wire (`onAcpMessage`), and the
/// top level then says nothing more; quiet output gives the agent's details. Each output is
/// what acpx printed for the same run on `model-agent.py`.
struct ExecSetupErrorTests {
    struct Run {
        var code: Int32
        var out: String
        var err: String
    }

    /// `acpx --approve-all --format <format> --model m2 --agent <model agent> exec hi`, the
    /// agent answering the model's request with `error`.
    private func exec(format: String, error: String, legacy: Bool = false) async throws -> Run {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py")
        let agent = "/usr/bin/env MODEL_AGENT_MODEL_ERROR='\(error)' " + (legacy ? "MODEL_AGENT_LEGACY=1 " : "")
            + "'\(python)' '\(fixture.path)'"
        let arguments = ["--approve-all", "--format", format, "--model", "m2", "--cwd", NSTemporaryDirectory(),
                         "--agent", agent, "exec", "hi"]
        return await withIsolatedStore {
            let capture = Console.Capture()
            let code: Int32 = await withCheckedContinuation { continuation in
                Thread {
                    continuation.resume(returning: Console.$capture.withValue(capture) { runCommandLine(arguments) })
                }.start()
            }
            return Run(code: code, out: capture.out, err: capture.err)
        }
    }

    @Test(.enabled(if: mockPythonAvailable), arguments: [false, true])
    func theAgentsErrorIsShownAndNothingMore(legacy: Bool) async throws {
        let run = try await exec(format: "text", error: #"{"code":-32002,"message":"Session gone"}"#, legacy: legacy)
        #expect(run.code == 4)
        #expect(run.out.hasSuffix("\n[error] RUNTIME: Session gone\n"), "\(run.out)")
        #expect(run.err.isEmpty, "\(run.err)")
    }

    @Test(.enabled(if: mockPythonAvailable))
    func quietOutputGivesTheAgentsDetails() async throws {
        let run = try await exec(
            format: "quiet",
            error: #"{"code":-32603,"message":"Internal error","data":{"details":"model backend down"}}"#)
        #expect(run.code == 1)
        #expect(run.err == "[acpx] error: RUNTIME model backend down\n")
    }
}
