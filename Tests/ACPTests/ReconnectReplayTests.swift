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
            _ = try await daemon.setModel(sessionId: id, modelId: "sonnet")
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
            // Model first: a config option can depend on which model is selected.
            #expect(
                replayed == ["session/set_model", "session/set_mode", "session/set_config_option"])
        }
    }

    /// A reconnect that falls back to a fresh session still creates it with the
    /// session's options: upstream builds every `createSession` from the options
    /// its client was made with, and on a reconnect those come from the record.
    /// Without this the session that actually receives the prompt runs with none
    /// of them — the model, tool allow-list and turn cap silently lapse.
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
            _ = try await restarted.runPrompt(sessionId: id, text: "ping")

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

    /// The record keeps the user's intent even when the agent will not take it back, so
    /// a retired model cannot strand the session on an unusable reconnect. The agent
    /// takes the session itself back here: a new session in its place replaces the
    /// advertised model state with its own, as acpx's does (#56).
    @Test(.enabled(if: mockPythonAvailable))
    func aRejectedSelectionDoesNotFailTheReconnect() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: "/usr/bin/env MOCK_LOAD_SESSION=ok \(command)", cwd: NSTemporaryDirectory())

            // Pin something the mock has no idea about, behind the daemon's back.
            var record = try #require(SessionStore.loadRecord(id))
            var acpx = record.acpx ?? SessionAcpxState()
            acpx.currentModelId = "no-such-model"
            acpx.desiredConfigOptions = ["no-such-option": "value"]
            record.acpx = acpx
            try SessionStore.writeRecord(record)

            let restarted = ACPXDaemonBackend(inheritAgentStderr: false)
            let answer = try await restarted.runPrompt(sessionId: id, text: "ping")

            #expect(!answer.isEmpty)
            #expect(SessionStore.loadRecord(id)?.acpx?.currentModelId == "no-such-model")
        }
    }

    /// When the agent exposes model selection as a config option, the choice lives in
    /// `desired_config_options` under that option's id while `current_model_id` can
    /// still hold the advertised default. The option has to go first — ahead of the mode
    /// and of the other options — not wherever dictionary order happens to put it.
    @Test(.enabled(if: mockPythonAvailable))
    func aModelHeldAsAConfigOptionIsReplayedFirst() async throws {
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
            // The agent advertises model selection as a config option named `model`…
            acpx.configOptions = .array([
                .object([
                    "id": .string("model"), "type": .string("select"),
                    "category": .string("model"), "name": .string("Model"),
                    "currentValue": .string("haiku"),
                    "options": .array([
                        .object(["value": .string("haiku"), "name": .string("Haiku")]),
                        .object(["value": .string("opus"), "name": .string("Opus")])
                    ])
                ])
            ])
            acpx.modelControl = "config_option"
            // …the record's `current_model_id` still holds the advertised default…
            acpx.currentModelId = "haiku"
            // …while the user's actual choice, and an unrelated option that sorts before
            // it, live among the desired options.
            acpx.desiredConfigOptions = ["model": "opus", "effort": "high"]
            acpx.desiredModeId = "auto"
            record.acpx = acpx
            try SessionStore.writeRecord(record)

            let restarted = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await restarted.runPrompt(sessionId: id, text: "ping")

            let entries = try String(contentsOf: log, encoding: .utf8)
                .split(separator: "\n")
                .compactMap {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                }
            let lastReconnect = try #require(
                entries.lastIndex { ($0["method"] as? String) == "session/load" })
            let replayed = entries[lastReconnect...].compactMap { entry -> String? in
                guard let method = entry["method"] as? String, method.hasPrefix("session/set_")
                else { return nil }
                if method == "session/set_config_option",
                    let params = entry["params"] as? [String: Any],
                    let configId = params["configId"] as? String {
                    return "\(method):\(configId)"
                }
                return method
            }

            // The model option first, then the mode, then the rest — and no legacy
            // `session/set_model` carrying the stale default.
            #expect(replayed == [
                "session/set_config_option:model", "session/set_mode",
                "session/set_config_option:effort"
            ])
        }
    }
}
