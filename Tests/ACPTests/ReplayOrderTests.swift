@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// What a reconnect puts back, in acpx 0.19.1's order and on its terms (#73): the saved
/// mode only onto a fresh session, then the pinned model — even unchanged — then each
/// saved option the model's reply still accepts; a control leaves what it replaces
/// alone. Each expectation is the request sequence acpx sends `model-agent.py` for the
/// same record.
extension DaemonToolsTests {
    /// A session on `model-agent.py`, pinned to `m2`, with `edit` applied to its record
    /// behind the daemon's back. Returns the session's id and the request log.
    ///
    /// - Parameter environment: more of the fixture's `MODEL_AGENT_*` settings, as
    ///   `NAME='value' ` pairs.
    func pinnedSession(
        load: Bool = false, models: String? = nil, environment: String = "",
        _ edit: (inout SessionAcpxState) -> Void = { _ in }
    ) async throws -> (id: String, log: URL) {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/model-agent.py")
        try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
        let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
        let modelsFile = ACPXPaths.baseDir.appendingPathComponent("models.txt")
        try "m1,m2".write(to: modelsFile, atomically: true, encoding: .utf8)
        let command = "/usr/bin/env MODEL_AGENT_LOG='\(log.path)' MODEL_AGENT_MODELS_FILE='\(modelsFile.path)' "
            + (load ? "MODEL_AGENT_LOAD=1 " : "") + environment + "'\(python)' '\(fixture.path)'"
        var options = SessionAcpxState.SessionOptions()
        options.model = "m2"
        let created = try await SessionEngine.createSession(
            agentCommand: command, cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll,
            authCredentials: [:], authPolicy: "skip", sessionOptions: options)
        var record = try #require(SessionStore.loadRecord(created.acpxRecordId))
        var acpx = record.acpx ?? SessionAcpxState()
        edit(&acpx)
        record.acpx = acpx
        try SessionStore.writeRecord(record)
        if let models { try models.write(to: modelsFile, atomically: true, encoding: .utf8) }
        try "".write(to: log, atomically: true, encoding: .utf8)
        return (created.acpxRecordId, log)
    }

    /// A loaded session kept its mode, so none is sent; the pinned model is, although
    /// the session already has it, and then the options.
    @Test(.enabled(if: mockPythonAvailable))
    func aLoadedSessionGetsTheModelAndOptionsBackButNotTheMode() async throws {
        try await withIsolatedStore {
            let (id, log) = try await pinnedSession(load: true) { acpx in
                acpx.desiredModeId = "plan"
                acpx.desiredConfigOptions = ["effort": "high"]
            }
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "hi")
            #expect(try Self.modelAgentRequests(log) == [
                "session/load", "session/set_config_option model=m2", "session/set_config_option effort=high",
                "session/prompt"
            ])
        }
    }

    /// Only the mode the user chose is put back — never the one the session last
    /// reported — and only onto a fresh session.
    @Test(.enabled(if: mockPythonAvailable))
    func aReportedModeIsNotPutBack() async throws {
        try await withIsolatedStore {
            let (id, log) = try await pinnedSession { acpx in acpx.currentModeId = "plan" }
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "hi")
            #expect(try Self.modelAgentRequests(log) == [
                "session/new", "session/set_config_option model=m2", "session/prompt"
            ])
        }
    }

    /// A saved value the model's reply no longer offers is not sent: the reply is the
    /// authority on what the model allows, and the record follows it.
    @Test(.enabled(if: mockPythonAvailable))
    func anOptionTheModelNoLongerOffersIsSkipped() async throws {
        try await withIsolatedStore {
            let (id, log) = try await pinnedSession { acpx in acpx.desiredConfigOptions = ["effort": "extreme"] }
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "hi")
            #expect(try Self.modelAgentRequests(log) == [
                "session/new", "session/set_config_option model=m2", "session/prompt"
            ])
            #expect(SessionStore.loadRecord(id)?.acpx?.desiredConfigOptions == ["effort": "low"])
        }
    }

    /// A pinned model the agent no longer offers fails the turn before the prompt, and
    /// the record stays as it was — acpx's `SessionModelReplayError`.
    @Test(.enabled(if: mockPythonAvailable))
    func aRetiredModelFailsTheTurnAndKeepsTheRecord() async throws {
        try await withIsolatedStore {
            let (id, log) = try await pinnedSession(models: "m1,m3")
            let before = try #require(SessionStore.loadRecord(id))
            let failure = await #expect(throws: SessionReplayError.self) {
                _ = try await ACPXDaemonBackend(inheritAgentStderr: false).runPrompt(sessionId: id, text: "hi")
            }
            #expect(failure?.localizedDescription == """
                Failed to replay saved session model m2 on ACP session model-session-1: Cannot replay saved \
                model "m2": the ACP agent did not advertise that model. Available models: m1, m3.
                """)
            #expect(try Self.modelAgentRequests(log) == ["session/new"])
            let after = try #require(SessionStore.loadRecord(id))
            #expect(after.acpSessionId == before.acpSessionId)
            #expect(after.acpx?.sessionOptions?.model == "m2")
            #expect(after.acpx?.currentModelId == before.acpx?.currentModelId)
            #expect(after.acpx?.availableModels == before.acpx?.availableModels)
        }
    }

    /// A control leaves what it replaces alone: `set-mode` does not put the saved mode
    /// back first, `set model` neither the model nor the options, `set effort` not
    /// effort — acpx's `replacingMode` and `replacingConfigOption`.
    @Test(.enabled(if: mockPythonAvailable))
    func aControlLeavesWhatItReplacesAlone() async throws {
        try await withIsolatedStore {
            let (id, log) = try await pinnedSession { acpx in
                acpx.desiredModeId = "plan"
                acpx.desiredConfigOptions = ["effort": "high"]
            }
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).setMode(sessionId: id, modeId: "code")
            #expect(try Self.modelAgentRequests(log) == [
                "session/new", "session/set_config_option model=m2", "session/set_config_option effort=high",
                "session/set_mode code"
            ])

            try "".write(to: log, atomically: true, encoding: .utf8)
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false).setModel(sessionId: id, modelId: "m1")
            #expect(try Self.modelAgentRequests(log) == [
                "session/new", "session/set_mode code", "session/set_config_option model=m1"
            ])

            try "".write(to: log, atomically: true, encoding: .utf8)
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .setConfigOption(sessionId: id, configId: "effort", value: "low")
            #expect(try Self.modelAgentRequests(log) == [
                "session/new", "session/set_mode code", "session/set_config_option model=m1",
                "session/set_config_option effort=low"
            ])
        }
    }
}
