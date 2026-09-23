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

    /// The record keeps the user's intent even when the agent will not take it back, so
    /// a retired model cannot strand the session on an unusable reconnect.
    @Test(.enabled(if: mockPythonAvailable))
    func aRejectedSelectionDoesNotFailTheReconnect() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, cwd: NSTemporaryDirectory())

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
}
