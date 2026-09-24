@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// What a reconnect restores. A daemon restart, an adapter exit or a fresh-session
/// fallback must not leave a session on the agent's defaults while its record still
/// claims the model, mode and options the user chose (acpx 0.13.1 / 0.13.2 — issue #28).
extension DaemonToolsTests {
    @Test(.enabled(if: mockPythonAvailable))
    func savedSelectionsAreReappliedOnReconnect() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try FileManager.default.createDirectory(
                at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            let loggedCommand = "/usr/bin/env MOCK_REQUEST_LOG='\(log.path)' \(command)"

            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand, cwd: NSTemporaryDirectory())
            // The mock advertises no models, so acpx's `setSessionModel` refuses one —
            // and nothing about models is left on the record to put back.
            await #expect(throws: ModelApplication.UnsupportedError.self) {
                try await daemon.setModel(sessionId: id, modelId: "sonnet")
            }
            _ = try await daemon.setMode(sessionId: id, modeId: "auto")
            _ = try await daemon.setConfigOption(sessionId: id, configId: "effort", value: "high")

            // A fresh backend holds nothing live — a daemon restart. The next call has to
            // reconnect, and the record's selections must go back on the wire.
            let restarted = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await restarted.runPrompt(sessionId: id, text: "ping")

            let methods = try String(contentsOf: log, encoding: .utf8)
                .split(separator: "\n")
                .compactMap {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                }
                .compactMap { $0["method"] as? String }

            let lastReconnect = try #require(methods.lastIndex(of: "session/load"))
            let replayed = methods[lastReconnect...].filter { $0.hasPrefix("session/set_") }
            // The mode, then the options. (The model goes first when there is one — see
            // `SessionNewModelTests.aLaterSelectionIsTheOneReplayed`.)
            #expect(replayed == ["session/set_mode", "session/set_config_option"])
        }
    }

    /// A reconnect that falls back to a fresh session still creates it with the
    /// session's options: upstream builds every `createSession` from the options
    /// its client was made with, and on a reconnect those come from the record.
    /// Without this the session that actually receives the prompt runs with none
    /// of them — the model, tool allow-list and turn cap silently lapse.
    ///
    /// acpx 0.19.1 then puts the pinned model back on the new session, which advertises
    /// no models here, so the turn fails as a retryable replay failure (#73).
    @Test(.enabled(if: mockPythonAvailable))
    func theFallbackSessionIsCreatedWithTheRecordsOptions() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try FileManager.default.createDirectory(
                at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            let loggedCommand = "/usr/bin/env MOCK_REQUEST_LOG='\(log.path)' \(command)"

            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand, cwd: NSTemporaryDirectory())

            var record = try #require(SessionStore.loadRecord(id))
            var acpx = record.acpx ?? SessionAcpxState()
            var options = SessionAcpxState.SessionOptions()
            options.model = "sonnet"
            options.allowedTools = ["Read"]
            options.maxTurns = 4
            options.systemPrompt = .string("be terse")
            acpx.sessionOptions = options
            record.acpx = acpx
            try SessionStore.writeRecord(record)

            // The mock no longer has the session a restarted daemon asks it to load
            // (`-32002`), so the daemon takes the fresh-session fallback.
            let restarted = ACPXDaemonBackend(inheritAgentStderr: false)
            let failure = await #expect(throws: SessionReplayError.self) {
                _ = try await restarted.runPrompt(sessionId: id, text: "ping")
            }
            #expect(failure?.localizedDescription == """
                Failed to replay saved session model sonnet on ACP session mock-session-1: Cannot replay \
                saved model "sonnet": the ACP agent did not advertise model support through a session \
                config option or legacy models metadata, and the adapter does not support a startup \
                model flag.
                """)

            let requests = try String(contentsOf: log, encoding: .utf8)
                .split(separator: "\n")
                .compactMap {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                }
            #expect(requests.contains { $0["method"] as? String == "session/load" })
            let creations = requests.filter { $0["method"] as? String == "session/new" }
            #expect(creations.count == 2, "one at creation, one for the fallback")

            let fallback = try #require(creations.last?["params"] as? [String: Any])
            let meta = try #require(fallback["_meta"] as? [String: Any])
            #expect(meta["systemPrompt"] as? String == "be terse")
            let claudeOptions = try #require(
                (meta["claudeCode"] as? [String: Any])?["options"] as? [String: Any])
            #expect(claudeOptions["model"] as? String == "sonnet")
            #expect(claudeOptions["allowedTools"] as? [String] == ["Read"])
            #expect(claudeOptions["maxTurns"] as? Int == 4)
            // The mock is not Claude Code's adapter, so its settings stay out.
            #expect(claudeOptions["settingSources"] == nil)
        }
    }

    /// A saved option the agent refuses to take back fails the turn, as a retryable
    /// replay failure — acpx 0.19.1's `SessionConfigOptionReplayError` (#73). The record
    /// keeps the user's intent and its session, and the agent is not held: the next turn
    /// connects again, and asks again.
    @Test(.enabled(if: mockPythonAvailable))
    func aRefusedSelectionFailsTheTurnAndKeepsTheRecord() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            let refusing = "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_SET_CONFIG_OPTION_ERROR=1 "
                + "MOCK_REQUEST_LOG='\(log.path)' \(command)"
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: refusing, cwd: NSTemporaryDirectory())
            var record = try #require(SessionStore.loadRecord(id))
            var acpx = record.acpx ?? SessionAcpxState()
            acpx.desiredConfigOptions = ["effort": "high"]
            record.acpx = acpx
            try SessionStore.writeRecord(record)

            let restarted = ACPXDaemonBackend(inheritAgentStderr: false)
            let failure = await #expect(throws: SessionReplayError.self) {
                _ = try await restarted.runPrompt(sessionId: id, text: "ping")
            }
            #expect(failure?.localizedDescription == """
                Failed to replay saved session config option effort on ACP session \(record.acpSessionId): \
                Invalid params
                """)
            #expect(failure?.detailCode == "SESSION_CONFIG_OPTION_REPLAY_FAILED" && failure?.retryable == true)
            let after = try #require(SessionStore.loadRecord(id))
            #expect(after.acpSessionId == record.acpSessionId)
            #expect(after.acpx?.desiredConfigOptions == ["effort": "high"])

            _ = try? await restarted.runPrompt(sessionId: id, text: "again")
            #expect(try Self.requestMethods(log).filter { $0 == "session/load" }.count == 2)
        }
    }

    /// The methods `mock-agent.py` logged, in order.
    private static func requestMethods(_ log: URL) throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap {
            ((try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any])?["method"] as? String
        }
    }

    /// A model an earlier SwiftACP saved as the model option's selection — `set model`
    /// did not pin then, and acpx never writes one — is put back as the model: after the
    /// mode, ahead of the other options, and pinned, as `set model` records it now. A
    /// fresh session gets the saved mode first, as acpx 0.19.1's replay orders them.
    @Test(.enabled(if: mockPythonAvailable))
    func aModelSavedAsItsOptionIsReplayedAsTheModel() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/model-agent.py")
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            let command = "/usr/bin/env MODEL_AGENT_LOG='\(log.path)' '\(python)' '\(fixture.path)'"
            let id = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            var record = try #require(SessionStore.loadRecord(id))
            var acpx = try #require(record.acpx)
            acpx.desiredConfigOptions = ["effort": "high", "model": "m2"]
            acpx.desiredModeId = "plan"
            record.acpx = acpx
            try SessionStore.writeRecord(record)

            let before = try Self.modelAgentRequests(log).count
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "hi")
            #expect(Array(try Self.modelAgentRequests(log).dropFirst(before)) == [
                "session/new", "session/set_mode plan", "session/set_config_option model=m2",
                "session/set_config_option effort=high", "session/prompt"
            ])
            let after = try #require(SessionStore.loadRecord(id)?.acpx)
            #expect(after.sessionOptions?.model == "m2")
            #expect(after.desiredConfigOptions == ["effort": "high"])
        }
    }

    /// The session requests `model-agent.py` logged: a mode, model or option named.
    static func modelAgentRequests(_ log: URL) throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { line in
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let method = message["method"] as? String, method.hasPrefix("session/")
            else { return nil }
            let params = message["params"] as? [String: Any] ?? [:]
            if let modeId = params["modeId"] as? String { return "\(method) \(modeId)" }
            if let modelId = params["modelId"] as? String { return "\(method) \(modelId)" }
            if let configId = params["configId"] as? String, let value = params["value"] as? String {
                return "\(method) \(configId)=\(value)"
            }
            return method
        }
    }
}
