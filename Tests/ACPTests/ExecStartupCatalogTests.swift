@testable import ACPXCore
@testable import ACPXFlows
@testable import acpx
import Foundation
import JSONFoundation
import Testing

/// A temporary session's catalog, as acpx main keeps what the agent announces while the session
/// is created (openclaw/acpx#794). Each case is one of acpx's own
/// (`test/run-once-model-catalog.test.ts`), run on `catalog-agent.py`. It sends
/// `config_option_update`s before `session/new` answers and after it, and the run is held once
/// answered until those after it have come, as acpx's test holds the session's creation.
@Suite(.serialized, .agentLane, .timeLimit(.minutes(1))) struct ExecStartupCatalogTests {
    static let sessionId = "creation-catalog-session"
    static let foreignId = "foreign-catalog-session"
    static let adapterError = "Synthetic catalog setter rejection"

    struct Update: Sendable {
        let sessionId: String
        let configOptions: String
    }

    enum Request: Sendable {
        case model(String)
        case config(String)
    }

    enum Outcome: Sendable, Equatable {
        case success
        case missingCapability
        case unadvertisedModel
        case adapter(String)
    }

    struct Scenario: Sendable, CustomTestStringConvertible {
        let name: String
        let initial: String
        var beforeResponse: [Update] = []
        var afterResponse: [Update] = []
        let request: Request
        var rejectSetter: String?
        /// Each setter call, as `<method> <id or config>=<value>`.
        let controls: [String]
        let expected: Outcome

        var testDescription: String { name }
    }

    static func modelConfig(_ prefix: String) -> String {
        """
        [{"id":"llm","name":"Model","category":"model","type":"select","currentValue":"\(prefix)-current",\
        "options":[{"value":"\(prefix)-current","name":"\(prefix)-current"},\
        {"value":"\(prefix)-target","name":"\(prefix)-target"}]}]
        """
    }

    static let effort = """
        [{"id":"effort","name":"Effort","type":"select","currentValue":"low",\
        "options":[{"value":"low","name":"low"},{"value":"high","name":"high"}]}]
        """
    static let configA = #"{"sessionId":"\#(sessionId)","configOptions":\#(modelConfig("a"))}"#
    static let legacyL = #"""
        {"sessionId":"\#(sessionId)","models":{"currentModelId":"l-current",\#
        "availableModels":[{"modelId":"l-current","name":"l-current"},{"modelId":"l-target","name":"l-target"}]}}
        """#

    static func owned(_ options: String) -> Update { Update(sessionId: sessionId, configOptions: options) }
    static func configCall(_ value: String) -> String { "session/set_config_option llm=\(value)" }
    static func legacyCall(_ model: String) -> String { "session/set_model \(model)" }

    static let scenarios: [Scenario] = [
        Scenario(
            name: "owned B-only config selection", initial: configA, afterResponse: [owned(modelConfig("b"))],
            request: .config("b-target"), controls: [configCall("b-target")], expected: .success),
        Scenario(
            name: "owned B-only startup model selection", initial: configA, afterResponse: [owned(modelConfig("b"))],
            request: .model("b-target"), controls: [configCall("b-target")], expected: .success),
        Scenario(
            name: "owned current model is a no-op", initial: configA, afterResponse: [owned(modelConfig("b"))],
            request: .model("b-current"), controls: [], expected: .success),
        Scenario(
            name: "B then C uses the latest callback", initial: configA,
            afterResponse: [owned(modelConfig("b")), owned(modelConfig("c"))], request: .config("c-target"),
            controls: [configCall("c-target")], expected: .success),
        Scenario(
            name: "owned B rejects a selector removed from A", initial: configA,
            afterResponse: [owned(modelConfig("b"))], request: .config("a-target"), controls: [],
            expected: .unadvertisedModel),
        Scenario(
            name: "empty config catalog removes startup model support", initial: configA, afterResponse: [owned("[]")],
            request: .model("a-target"), controls: [], expected: .missingCapability),
        Scenario(
            name: "raw config after removal reaches the adapter", initial: configA, afterResponse: [owned("[]")],
            request: .config("raw-after-removal"), rejectSetter: "removed-config",
            controls: [configCall("raw-after-removal")], expected: .adapter("removed-config")),
        Scenario(
            name: "legacy then config then removal does not resurrect legacy", initial: legacyL,
            afterResponse: [owned(modelConfig("b")), owned("[]")], request: .model("l-target"), controls: [],
            expected: .missingCapability),
        Scenario(
            name: "empty config update preserves existing legacy control", initial: legacyL,
            afterResponse: [owned("[]")], request: .model("l-target"), controls: [legacyCall("l-target")],
            expected: .success),
        Scenario(
            name: "unrelated config update preserves existing legacy control", initial: legacyL,
            afterResponse: [owned(effort)], request: .model("l-target"), controls: [legacyCall("l-target")],
            expected: .success),
        Scenario(
            name: "foreign callback cannot replace A", initial: configA,
            afterResponse: [Update(sessionId: foreignId, configOptions: modelConfig("b"))],
            request: .model("a-target"), controls: [configCall("a-target")], expected: .success),
        Scenario(
            name: "pre-assignment callback cannot replace the later A response", initial: configA,
            beforeResponse: [owned(modelConfig("b"))], request: .model("a-target"),
            controls: [configCall("a-target")], expected: .success),
        Scenario(
            name: "no-update A preserves startup defaults", initial: configA, request: .model("a-target"),
            controls: [configCall("a-target")], expected: .success),
        Scenario(
            name: "valid B setter rejection prevents the prompt", initial: configA,
            afterResponse: [owned(modelConfig("b"))], request: .model("b-target"),
            rejectSetter: "valid-setter-rejected", controls: [configCall("b-target")],
            expected: .adapter("valid-setter-rejected")),
        Scenario(
            name: "foreign model history cannot suppress legacy seeding", initial: legacyL,
            afterResponse: [Update(sessionId: foreignId, configOptions: modelConfig("b")), owned("[]")],
            request: .model("l-target"), controls: [legacyCall("l-target")], expected: .success)
    ]

    struct Run {
        var code: Int32
        var err: String
        /// What the agent logged: each setter call it `accepted` or `rejected`, and each `prompt`.
        var entries: [(kind: String, call: String?)]

        func calls(_ kind: String) -> [String] { entries.filter { $0.kind == kind }.compactMap(\.call) }
    }

    /// `scenario`'s fixture in `directory`, and the command that starts `catalog-agent.py` on it,
    /// logging to the file it returns.
    private func agent(for scenario: Scenario, in directory: URL) throws -> (command: String, log: URL) {
        let python = try #require(AgentRegistry.which("python3"))
        let agentScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/catalog-agent.py")
        let fixture = directory.appendingPathComponent("fixture.json")
        let log = directory.appendingPathComponent("agent.jsonl")
        let updates: ([Update]) -> String = { list in
            "[" + list.map { #"{"sessionId":"\#($0.sessionId)","configOptions":\#($0.configOptions)}"# }
                .joined(separator: ",") + "]"
        }
        let reject = scenario.rejectSetter.map { #""\#($0)""# } ?? "null"
        let json = #"{"initial":\#(scenario.initial),"beforeResponse":\#(updates(scenario.beforeResponse)),"#
            + #""afterResponse":\#(updates(scenario.afterResponse)),"rejectSetter":\#(reject),"#
            + #""errorMessage":"\#(Self.adapterError)"}"#
        try Data(json.utf8).write(to: fixture)
        let command = "/usr/bin/env CATALOG_AGENT_FIXTURE='\(fixture.path)' CATALOG_AGENT_LOG='\(log.path)' "
            + "'\(python)' '\(agentScript.path)'"
        return (command, log)
    }

    /// A new directory for a run, and a way to remove it.
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// What the agent logged: each setter call as `<method> <id or config>=<value>`, and each prompt.
    private func entries(_ log: URL) -> [(kind: String, call: String?)] {
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
        return lines.compactMap { line -> (kind: String, call: String?)? in
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  case .object(let fields) = entry, case .string(let kind)? = fields["kind"]
            else { return nil }
            guard case .string(let method)? = fields["method"], case .object(let params)? = fields["params"]
            else { return (kind, nil) }
            if case .string(let configId)? = params["configId"], case .string(let value)? = params["value"] {
                return (kind, "\(method) \(configId)=\(value)")
            }
            if case .string(let model)? = params["modelId"] { return (kind, "\(method) \(model)") }
            return (kind, method)
        }
    }

    /// Hold the run once `session/new` has answered until `scenario`'s updates after it have come.
    private static func hold(_ scenario: Scenario) -> @Sendable (ModelApplication.ControlState) async -> Void {
        let seen = scenario.afterResponse.count
        return { await $0.updatesSeen(seen) }
    }

    private func run(_ scenario: Scenario) async throws -> Run {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (agent, log) = try agent(for: scenario, in: directory)
        // `--model` is the root's, `--config-option` exec's own.
        var global: [String] = []
        var execOptions: [String] = []
        switch scenario.request {
        case .model(let model): global = ["--model", model]
        case .config(let value): execOptions = ["--config-option", "llm=\(value)"]
        }
        let arguments = ["--format", "quiet", "--approve-all", "--cwd", directory.path] + global
            + ["--agent", agent, "exec"] + execOptions + ["hi"]
        let hold = Self.hold(scenario)
        let (code, err): (Int32, String) = await withIsolatedStore {
            let capture = Console.Capture()
            let code = await onThreadOfItsOwn {
                ExecCommand.$sessionAnswered.withValue(hold) {
                    Console.$capture.withValue(capture) { runCommandLine(arguments) }
                }
            }
            return (code, capture.err)
        }
        return Run(code: code, err: err, entries: entries(log))
    }

    @Test(.enabled(if: mockPythonAvailable), arguments: scenarios)
    func startupSelectionsGoByTheLatestCatalog(_ scenario: Scenario) async throws {
        let run = try await run(scenario)
        let calls = run.calls("accepted") + run.calls("rejected")
        #expect(calls == scenario.controls, "\(run.err)")
        #expect(run.calls("accepted") == (scenario.rejectSetter == nil ? scenario.controls : []))
        #expect(run.calls("rejected") == (scenario.rejectSetter == nil ? [] : scenario.controls))
        #expect(run.entries.filter { $0.kind == "prompt" }.count == (scenario.expected == .success ? 1 : 0))
        switch scenario.expected {
        case .success:
            #expect(run.code == 0, "\(run.err)")
        case .missingCapability:
            #expect(run.code == 1)
            #expect(run.err.contains("did not advertise model support"), "\(run.err)")
        case .unadvertisedModel:
            #expect(run.code == 1)
            #expect(run.err.contains("did not advertise that model"), "\(run.err)")
        case .adapter:
            #expect(run.code != 0)
            #expect(run.err.contains(Self.adapterError), "\(run.err)")
        }
    }

    /// `compare` goes through acpx's `runOnce` too: a model the agent announced once
    /// `session/new` had answered is one its run selects.
    @Test(.enabled(if: mockPythonAvailable))
    func compareSelectsByTheLatestCatalog() async throws {
        let scenario = try #require(Self.scenarios.first { $0.name == "owned B-only startup model selection" })
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (agent, log) = try agent(for: scenario, in: directory)
        let arguments = ["--format", "json", "--approve-all", "--cwd", directory.path, "--model", "b-target",
                         "compare", agent, "hi"]
        let hold = Self.hold(scenario)
        let (code, out): (Int32, String) = await withIsolatedStore {
            let capture = Console.Capture()
            let code = await onThreadOfItsOwn {
                ExecCommand.$sessionAnswered.withValue(hold) {
                    Console.$capture.withValue(capture) { runCommandLine(arguments) }
                }
            }
            return (code, capture.out)
        }
        let rows = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]]
        #expect(code == ExitCodes.success, "\(out)")
        #expect(rows?.first?["status"] as? String == "ok", "\(out)")
        #expect(entries(log).filter { $0.kind == "accepted" }.compactMap(\.call) == [Self.configCall("b-target")])
    }

    /// So does a flow's ACP turn.
    @Test(.enabled(if: mockPythonAvailable))
    func aFlowTurnSelectsByTheLatestCatalog() async throws {
        let scenario = try #require(Self.scenarios.first { $0.name == "owned B-only startup model selection" })
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (agentCommand, log) = try agent(for: scenario, in: directory)
        let agent = FlowAgent(agentName: "catalog", agentCommand: agentCommand, agentArgv: nil, cwd: directory.path)
        let hold = Self.hold(scenario)
        try await withIsolatedStore {
            let config = try ConfigLoader.load(cwd: directory.path)
            var flags = try Flags.resolveGlobalFlags(ScannedArgs(), config: config)
            flags.model = "b-target"
            let sessions = FlowAgentSessions(
                flags: flags, config: config, permission: .approveAll, permissionRules: nil, mcpServers: [])
            let attempt = FlowAttempt(nodeId: "ask", attemptId: "ask-1", startedAt: nowISO(), timeoutMs: nil)
            let turn = FlowTurn(
                agent: agent, prompt: [.text("hi")], onMessage: { _, _ in }, onSessionUpdate: { _ in },
                onClientOperation: {}, onSessionReady: { _ in }, control: FlowTurnControl(attempt: attempt))
            let sessionId = try await ExecCommand.$sessionAnswered.withValue(hold) {
                try await sessions.runIsolated(turn)
            }
            #expect(sessionId == Self.sessionId)
        }
        #expect(entries(log).filter { $0.kind == "accepted" }.compactMap(\.call) == [Self.configCall("b-target")])
        #expect(entries(log).filter { $0.kind == "prompt" }.count == 1)
    }
}
