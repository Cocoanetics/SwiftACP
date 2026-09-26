@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
import Testing

/// What `exec` knows of the session while it applies `--model` and `--config-option`:
/// acpx's `controlState` in `runOnce`, which takes in each `config_option_update` the
/// agent sends as it arrives (acpx 0.19.1 and 0.19.3 alike), and keeps what an
/// acknowledged selection left (0.19.3, #778).
struct ExecControlStateTests {
    struct Run {
        var code: Int32
        var err: String
        /// Each option the agent was asked to set, as `<configId>=<value>`.
        var selections: [String]
    }

    /// `acpx --agent <model agent with environment> exec <execOptions> hi`, in quiet format.
    private func exec(_ environment: String, _ execOptions: [String]) async throws -> Run {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("exec-control-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: log) }
        let agent = "/usr/bin/env MODEL_AGENT_LOG='\(log.path)' \(environment) '\(python)' '\(fixture.path)'"
        let arguments = ["--format", "quiet", "--approve-all", "--cwd", NSTemporaryDirectory(), "--agent", agent,
                         "exec"] + execOptions + ["hi"]
        let (code, err): (Int32, String) = await withIsolatedStore {
            let capture = Console.Capture()
            let code: Int32 = await withCheckedContinuation { continuation in
                Thread {
                    continuation.resume(returning: Console.$capture.withValue(capture) { runCommandLine(arguments) })
                }.start()
            }
            return (code, capture.err)
        }
        let selections = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { line -> String? in
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                      case .object(let fields) = message, fields["method"] == .string("session/set_config_option"),
                      case .object(let params)? = fields["params"], case .string(let id)? = params["configId"],
                      case .string(let value)? = params["value"]
                else { return nil }
                return "\(id)=\(value)"
            }
        return Run(code: code, err: err, selections: selections)
    }

    /// A model the agent announces in a `config_option_update` before it acknowledges a
    /// selection with `{}` is one a later `--config-option` can select.
    @Test(.enabled(if: mockPythonAvailable))
    func aModelTheAgentAnnouncesCanBeSelected() async throws {
        let run = try await exec(
            "MODEL_AGENT_EMPTY_REPLIES=1 MODEL_AGENT_ANNOUNCE_MODEL=m3",
            ["--config-option", "effort=high", "--config-option", "model=m3"])
        #expect(run.code == 0, "\(run.err)")
        #expect(run.selections == ["effort=high", "model=m3"])
    }

    /// Unannounced, the same model is refused before it reaches the agent: the one
    /// before was acknowledged, and the models it left are what `m3` is checked against.
    @Test(.enabled(if: mockPythonAvailable))
    func anUnannouncedModelIsRefused() async throws {
        let run = try await exec(
            "MODEL_AGENT_EMPTY_REPLIES=1", ["--config-option", "effort=high", "--config-option", "model=m3"])
        #expect(run.code == 1)
        #expect(run.err == """
            [acpx] error: RUNTIME Cannot apply --model "m3": the ACP agent did not advertise that model. \
            Available models: m1, m2.

            """)
        #expect(run.selections == ["effort=high"])
    }
}
