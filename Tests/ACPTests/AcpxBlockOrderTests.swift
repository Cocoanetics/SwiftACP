@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// The record's `acpx` block is written in the order acpx 0.19.1's object holds its
/// members (#121): a new session's as `sessions new` sets them, a prompt's and a
/// control's as the clone each builds (`cloneSessionAcpxState`), a read record's as
/// acpx's parser builds it — and a member set since in its place, or last. Each order
/// with the agent is the one acpx wrote for the same steps on `model-agent.py`. A new
/// session's model is selected as acpx 0.19.3 selects it (#778), which builds the block
/// anew: 0.19.1 set it in place, with `session_options` first on a legacy model list.
extension DaemonToolsTests {
    /// How `sessions new` leaves the block, by what the agent advertises and the model asked for.
    struct NewSession: Sendable, CustomTestStringConvertible {
        var legacy: Bool
        var model: String?
        var order: [String]
        var testDescription: String { "\(legacy ? "legacy models" : "config options"), model \(model ?? "-")" }
    }

    @Test(.enabled(if: mockPythonAvailable), arguments: [
        NewSession(legacy: false, model: nil, order: [
            "current_model_id", "available_models", "model_control", "config_options", "available_model_names"
        ]),
        NewSession(legacy: false, model: "m2", order: [
            "current_model_id", "available_models", "available_model_names", "model_control", "config_options",
            "session_options"
        ]),
        NewSession(legacy: true, model: nil, order: [
            "current_model_id", "available_models", "available_model_names", "model_control"
        ]),
        NewSession(legacy: true, model: "m2", order: [
            "current_model_id", "available_models", "available_model_names", "model_control", "session_options"
        ])
    ])
    func aNewSessionsBlockIsInTheOrderAcpxSetsIt(_ expected: NewSession) async throws {
        try await withIsolatedStore {
            let id = try await orderedSession(
                model: expected.model, environment: expected.legacy ? "MODEL_AGENT_LEGACY=1 " : "")
            #expect(try acpxOrder(id) == expected.order)
        }
    }

    /// A prompt builds the block anew — a place for each member, `available_model_names`
    /// in its own now — and so does setting an option, whose saved selection takes the
    /// place the clone keeps for it, and a model.
    @Test(.enabled(if: mockPythonAvailable))
    func aPromptAndAControlBuildTheBlockAnew() async throws {
        try await withIsolatedStore {
            let id = try await orderedSession(environment: "MODEL_AGENT_COMMANDS=1 ")
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await backend.runPrompt(sessionId: id, text: "hi")
            #expect(try acpxOrder(id) == [
                "current_model_id", "available_models", "available_model_names", "model_control",
                "available_commands", "config_options"
            ])
            let setOption = [
                "desired_config_options", "current_model_id", "available_models", "available_model_names",
                "model_control", "available_commands", "config_options"
            ]
            _ = try await backend.setConfigOption(sessionId: id, configId: "effort", value: "high")
            #expect(try acpxOrder(id) == setOption)
            // Read in the parser's order, built anew by the model's selection, and pinned.
            _ = try await backend.setModel(sessionId: id, modelId: "m2")
            #expect(try acpxOrder(id) == setOption + ["session_options"])
            await backend.releaseAll()
        }
    }

    /// Setting the mode builds nothing anew: the block as acpx's parser reads it, with the
    /// desired mode last — until the next prompt builds it anew, on the agent it holds.
    @Test(.enabled(if: mockPythonAvailable))
    func aModeIsSetOnTheBlockAsRead() async throws {
        try await withIsolatedStore {
            let id = try await orderedSession(environment: "MODEL_AGENT_COMMANDS=1 MODEL_AGENT_MODE_UPDATE=plan ")
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await backend.runPrompt(sessionId: id, text: "hi")
            #expect(try acpxOrder(id) == [
                "current_mode_id", "current_model_id", "available_models", "available_model_names", "model_control",
                "available_commands", "config_options"
            ])
            _ = try await backend.setMode(sessionId: id, modeId: "plan")
            #expect(try acpxOrder(id) == [
                "current_mode_id", "available_model_names", "current_model_id", "available_models", "model_control",
                "config_options", "available_commands", "desired_mode_id"
            ])
            _ = try await backend.runPrompt(sessionId: id, text: "hi")
            #expect(try acpxOrder(id) == [
                "current_mode_id", "desired_mode_id", "current_model_id", "available_models", "available_model_names",
                "model_control", "available_commands", "config_options"
            ])
            await backend.releaseAll()
        }
    }

    /// A prompt builds the block anew even when connecting reports no options to build it
    /// from: the legacy models are set in the prompt's own clone.
    @Test(.enabled(if: mockPythonAvailable))
    func aPromptBuildsTheBlockAnewWithoutOptions() async throws {
        try await withIsolatedStore {
            let id = try await orderedSession(environment: "MODEL_AGENT_LEGACY=1 MODEL_AGENT_COMMANDS=1 ")
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await backend.runPrompt(sessionId: id, text: "hi")
            #expect(try acpxOrder(id) == [
                "current_model_id", "available_models", "available_model_names", "model_control", "available_commands"
            ])
            await backend.releaseAll()
        }
    }

    /// A session on `model-agent.py`, with `environment` as `NAME=value ` pairs, created
    /// with `model` asked for.
    private func orderedSession(model: String? = nil, environment: String = "") async throws -> String {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/model-agent.py")
        let command = "/usr/bin/env " + environment + "'\(python)' '\(fixture.path)'"
        var options: SessionAcpxState.SessionOptions?
        if let model {
            options = SessionAcpxState.SessionOptions()
            options?.model = model
        }
        let created = try await SessionEngine.createSession(
            agentCommand: command, cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll,
            authCredentials: [:], authPolicy: "skip", sessionOptions: options)
        return created.acpxRecordId
    }

    /// The members of the stored record's `acpx` block, in the file's order, SwiftACP's own
    /// left out.
    private func acpxOrder(_ id: String) throws -> [String] {
        let data = try Data(contentsOf: ACPXPaths.sessionRecordPath(id))
        guard case .object(let members)? = WireJSON(parsing: data)?["acpx"] else { return [] }
        return members.map { String(decoding: $0.key, as: UTF16.self) }
            .filter { $0 != "mcp_servers" && $0 != "client_capabilities" }
    }
}

/// The block's order on its own: what a clone does to it, and a member set or deleted.
struct AcpxBlockSlotTests {
    /// The clone's order — `available_model_names` only when there are names — and no
    /// `reset_on_next_ensure`, which it does not copy.
    @Test func aCloneTakesItsOwnOrderAndDropsTheReset() {
        var state = SessionAcpxState()
        state.resetOnNextEnsure = true
        state.availableModels = ["m1"]
        state.currentModeId = "auto"
        let clone = state.cloned()
        #expect(clone.resetOnNextEnsure == nil)
        #expect(clone.slots == [
            "current_mode_id", "desired_mode_id", "desired_config_options", "current_model_id", "available_models",
            "model_control", "available_commands", "config_options", "session_options"
        ])
        state.availableModelNames = ["m1": "One"]
        #expect(state.cloned().slots.contains("available_model_names"))
    }

    /// A member set goes last unless it has a place, even one it keeps unset; a deleted
    /// one loses its place.
    @Test func aMemberSetKeepsItsPlaceUnlessDeleted() {
        var state = SessionAcpxState().cloned()
        state.availableModelNames = ["m1": "One"]
        #expect(state.slots.last == "available_model_names")
        state.currentModelId = "m1"
        #expect(state.slots.firstIndex(of: "current_model_id") == 3)
        state.currentModelId = nil
        state.forget("current_model_id")
        state.currentModelId = "m2"
        #expect(state.slots.last == "current_model_id")
    }

    /// Options without a model's clear the model state — deleting its members — so the
    /// legacy models set after them go last, as `sessions new` leaves them in acpx.
    @Test func aClearedModelStateIsSetAgainLast() throws {
        var state = SessionAcpxState()
        let low: [String: JSONValue] = ["value": .string("low"), "name": .string("Low")]
        let effort: [String: JSONValue] = [
            "id": .string("effort"), "type": .string("select"), "currentValue": .string("low"),
            "options": .array([.object(low)])
        ]
        ModelSupport.applyConfigOptions([.object(effort)], to: &state)
        let one: [String: JSONValue] = ["modelId": .string("m1"), "name": .string("One")]
        let fields: [String: JSONValue] = ["currentModelId": .string("m1"), "availableModels": .array([.object(one)])]
        let legacy = JSONValue.object(fields)
        let models = try #require(ModelSupport.modelState(fromLegacyModels: legacy))
        ModelSupport.applyAdvertisedModelState(models, to: &state)
        let present = state.slots.filter { ["config_options", "current_model_id", "available_models",
                                            "available_model_names", "model_control"].contains($0) }
        #expect(present == [
            "config_options", "current_model_id", "available_models", "available_model_names", "model_control"
        ])
    }

    /// A model selection on a read record writes `session_options` in the order acpx
    /// builds it, the model first, whatever order it was read in.
    @Test func sessionOptionsAreWrittenInAcpxsOrder() async throws {
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.sessionsDir, withIntermediateDirectories: true)
            let stored = ACPXPaths.sessionsDir.appendingPathComponent("read.json")
            try Data(#"""
                {"schema":"acpx.session.v1","acpx_record_id":"r1","acp_session_id":"s1","agent_command":"a",
                "cwd":"/w","created_at":"2026-09-01T10:00:00.000Z","last_used_at":"2026-09-01T10:00:00.000Z",
                "last_seq":0,"event_log":{"active_path":"/x","segment_count":1,"max_segment_bytes":1,
                "max_segments":1,"last_write_at":null,"last_write_error":null},"messages":[],
                "updated_at":"2026-09-01T10:00:00.000Z","cumulative_token_usage":{},"request_token_usage":{},
                "acpx":{"session_options":{"allowed_tools":["Read"]}}}
                """#.utf8).write(to: stored)
            var record = try #require(SessionStore.readRecord(at: stored))
            var acpx = try #require(record.acpx)
            ModelSupport.applyModelSelection("m2", response: nil, to: &acpx)
            record.acpx = acpx
            try SessionStore.writeRecord(record)
            let data = try Data(contentsOf: ACPXPaths.sessionRecordPath("r1"))
            guard case .object(let members)? = WireJSON(parsing: data)?["acpx"]?["session_options"] else {
                Issue.record("no session options")
                return
            }
            #expect(members.map { String(decoding: $0.key, as: UTF16.self) } == ["model", "allowed_tools"])
        }
    }
}
