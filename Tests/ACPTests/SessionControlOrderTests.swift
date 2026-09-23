@testable import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Drives ``ModelApplication/applySessionControls(connection:session:model:configOptions:agentCommand:onWarning:)``
/// — the sequence `exec` runs between `session/new` and the prompt — against a
/// real agent subprocess, and asserts the requests that actually reached it.
///
/// The expected traces were captured from npm acpx 0.19.1 against the same
/// advertisement, so these pin the order rather than merely describing it.
struct SessionControlOrderTests {
    /// Launches the config-option fixture and returns the requests it received.
    private func trace(
        legacy: Bool = false, model: String?,
        configOptions: [ModelApplication.ConfigOptionAssignment]
    ) async throws -> [(method: String, params: JSONValue)] {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py")
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acpx-controls-\(UUID().uuidString).ndjson")
        defer { try? FileManager.default.removeItem(at: log) }

        var environment = ProcessInfo.processInfo.environment
        environment["MODEL_AGENT_LOG"] = log.path
        if legacy { environment["MODEL_AGENT_LEGACY"] = "1" }

        let command = "'\(python)' '\(fixture.path)'"
        let agent = try await ACPAgent.launch(
            agent: command, cwd: NSTemporaryDirectory(), permission: .approveAll,
            environment: environment, inheritStderr: false)
        do {
            let session = try await agent.connection.newSession(
                NewSessionRequest(cwd: NSTemporaryDirectory(), mcpServers: []))
            try await ModelApplication.applySessionControls(
                connection: agent.connection, session: session, model: model,
                configOptions: configOptions, agentCommand: command)
        } catch {
            await agent.close()
            throw error
        }
        await agent.close()

        let lines = (try? String(contentsOf: log, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8),
                let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                case .object(let message) = value,
                case .string(let method)? = message["method"], method.hasPrefix("session/")
            else { return nil }
            return (method, message["params"] ?? .null)
        }
    }

    private func selection(_ trace: (method: String, params: JSONValue)) -> String {
        guard case .object(let params) = trace.params,
            case .string(let configId)? = params["configId"],
            case .string(let value)? = params["value"]
        else { return trace.method }
        return "\(trace.method) \(configId)=\(value)"
    }

    /// acpx applies `--model` before the first `--config-option`, whatever order
    /// they were written in, and the options themselves in the order given.
    @Test(.enabled(if: mockPythonAvailable))
    func theModelIsAppliedBeforeTheConfigOptions() async throws {
        let seen = try await trace(model: "m2", configOptions: [
            .init(configId: "effort", value: "high"),
            .init(configId: "effort", value: "low")
        ])
        #expect(seen.map(selection) == [
            "session/new",
            "session/set_config_option model=m2",
            "session/set_config_option effort=high",
            "session/set_config_option effort=low"
        ])
    }

    /// Selecting the model the session already reports costs no request at all.
    @Test(.enabled(if: mockPythonAvailable))
    func theCurrentModelIsNotReselected() async throws {
        let seen = try await trace(model: "m1", configOptions: [])
        #expect(seen.map(\.method) == ["session/new"])
    }

    /// An agent that advertises models as a config option is switched through
    /// `session/set_config_option`; one that only advertises legacy `models`
    /// metadata is switched through `session/set_model`.
    @Test(.enabled(if: mockPythonAvailable))
    func legacyModelMetadataIsSwitchedThroughSetModel() async throws {
        let seen = try await trace(legacy: true, model: "m2", configOptions: [])
        #expect(seen.map(\.method) == ["session/new", "session/set_model"])
    }

    /// An unadvertised model is refused locally: the agent is never asked, so a
    /// typo can't reach it as a silently-ignored selection.
    @Test(.enabled(if: mockPythonAvailable))
    func anUnadvertisedModelNeverReachesTheAgent() async throws {
        var seen: [(method: String, params: JSONValue)] = []
        let error = await #expect(throws: ModelApplication.UnsupportedError.self) {
            seen = try await trace(model: "bogus", configOptions: [
                .init(configId: "effort", value: "high")
            ])
        }
        #expect(error?.message == """
            Cannot apply --model "bogus": the ACP agent did not advertise that model. \
            Available models: m1, m2.
            """)
        #expect(seen.isEmpty)
    }

    /// Nothing is sent when the invocation asked for nothing — `exec` with no
    /// controls stays a bare `session/new` + prompt.
    @Test(.enabled(if: mockPythonAvailable))
    func noControlsMeansNoRequests() async throws {
        let seen = try await trace(model: nil, configOptions: [])
        #expect(seen.map(\.method) == ["session/new"])
    }
}
