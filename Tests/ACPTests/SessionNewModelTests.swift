@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// `sessions new --model` puts the model on the new session, as acpx's
/// `createFreshSessionState` does, and records what came of it
/// (`applyInitialModelSelection`) — including each model's name (#92). The requests
/// and records expected here are acpx 0.19.1's against the same advertisements.
@Suite(.serialized) struct SessionNewModelTests {
    private struct Created {
        var record: SessionRecord?
        var requests: [String]
        /// What the agent received for a daemon turn after the creation, when asked for.
        var turn: [String] = []
        /// The record after that turn.
        var afterTurn: SessionRecord?
    }

    /// Creates a session on the model fixture with `model` requested, returning the
    /// record it wrote and the session requests the agent received — and, with
    /// `thenPrompt`, what a daemon turn on it sent next.
    private func create(legacy: Bool = false, model: String?, thenPrompt: Bool = false) async throws -> Created {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/model-agent.py")
        return try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            let command = "/usr/bin/env MODEL_AGENT_LOG='\(log.path)' "
                + (legacy ? "MODEL_AGENT_LEGACY=1 " : "") + "'\(python)' '\(fixture.path)'"
            var options = SessionAcpxState.SessionOptions()
            options.model = model
            var created = Created(record: nil, requests: [])
            do {
                let record = try await SessionEngine.createSession(
                    agentCommand: command, cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll,
                    authCredentials: [:], authPolicy: "skip", sessionOptions: model == nil ? nil : options)
                created.record = SessionStore.loadRecord(record.acpxRecordId)
            } catch {
                created.requests = Self.requests(log)
                throw error
            }
            created.requests = Self.requests(log)
            if thenPrompt, let record = created.record {
                _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                    .runPrompt(sessionId: record.acpxRecordId, text: "hi")
                created.turn = Array(Self.requests(log).dropFirst(created.requests.count))
                created.afterTurn = SessionStore.loadRecord(record.acpxRecordId)
            }
            return created
        }
    }

    private static func requests(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  case .object(let message) = value, case .string(let method)? = message["method"],
                  method.hasPrefix("session/")
            else { return nil }
            if case .object(let params)? = message["params"] {
                if case .string(let modelId)? = params["modelId"] { return "\(method) \(modelId)" }
                if case .string(let configId)? = params["configId"], case .string(let value)? = params["value"] {
                    return "\(method) \(configId)=\(value)"
                }
            }
            return method
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aModelOptionIsSetThroughIt() async throws {
        let created = try await create(model: "m2")
        #expect(created.requests == ["session/new", "session/set_config_option model=m2"])
        let acpx = try #require(created.record?.acpx)
        #expect(acpx.currentModelId == "m2")
        #expect(acpx.availableModels == ["m1", "m2"])
        #expect(acpx.availableModelNames == ["m1": "One", "m2": "Two"])
        #expect(acpx.modelControl == "config_option")
        #expect(acpx.sessionOptions?.model == "m2")
        // The options the agent reported back replace the ones `session/new` gave.
        guard case .array(let options)? = acpx.configOptions, case .object(let model)? = options.first else {
            Issue.record("expected the reported config options: \(String(describing: acpx.configOptions))")
            return
        }
        #expect(model["currentValue"] == .string("m2"))
    }

    @Test(.enabled(if: mockPythonAvailable))
    func legacyModelsAreSetThroughSetModel() async throws {
        let created = try await create(legacy: true, model: "m2")
        #expect(created.requests == ["session/new", "session/set_model m2"])
        let acpx = try #require(created.record?.acpx)
        #expect(acpx.currentModelId == "m2")
        #expect(acpx.availableModelNames == ["m1": "One", "m2": "Two"])
        #expect(acpx.modelControl == "legacy_set_model")
    }

    /// The model the session is on already costs no request.
    @Test(.enabled(if: mockPythonAvailable))
    func theCurrentModelIsNotAskedFor() async throws {
        let created = try await create(model: "m1")
        #expect(created.requests == ["session/new"])
        #expect(created.record?.acpx?.currentModelId == "m1")
    }

    /// Without `--model` nothing is asked, and the names are still recorded.
    @Test(.enabled(if: mockPythonAvailable))
    func withoutAModelNothingIsAsked() async throws {
        let created = try await create(model: nil)
        #expect(created.requests == ["session/new"])
        #expect(created.record?.acpx?.availableModelNames == ["m1": "One", "m2": "Two"])
    }

    /// A model the agent does not advertise fails the creation, before the agent is
    /// asked for it, and no record is written.
    @Test(.enabled(if: mockPythonAvailable))
    func anUnadvertisedModelFailsTheCreation() async throws {
        let error = await #expect(throws: ModelApplication.UnsupportedError.self) {
            _ = try await create(model: "bogus")
        }
        #expect(error?.localizedDescription == """
            Cannot apply --model "bogus": the ACP agent did not advertise that model. \
            Available models: m1, m2.
            """)
    }

    /// The fixture cannot load a session, so the turn's reconnect starts a new one — on
    /// the agent's default model — and puts the pinned model back on it first, as acpx's
    /// `replayDesiredModel` does, through the control the session advertises.
    @Test(.enabled(if: mockPythonAvailable))
    func aReconnectPutsThePinnedModelBack() async throws {
        let options = try await create(model: "m2", thenPrompt: true)
        #expect(options.turn == ["session/new", "session/set_config_option model=m2", "session/prompt"])
        let legacy = try await create(legacy: true, model: "m2", thenPrompt: true)
        #expect(legacy.turn == ["session/new", "session/set_model m2", "session/prompt"])
        // The record says so, as acpx's `applyModelSelection` leaves it — not the
        // default the replacement session started on.
        #expect(options.afterTurn?.acpx?.currentModelId == "m2")
        #expect(legacy.afterTurn?.acpx?.currentModelId == "m2")
        guard case .array(let reported)? = options.afterTurn?.acpx?.configOptions,
              case .object(let model)? = reported.first
        else {
            Issue.record("expected the options the replay's reply reported")
            return
        }
        #expect(model["currentValue"] == .string("m2"))
    }

    /// A model chosen later with `set model` is the one pinned: a reconnect puts it back,
    /// not the one the session was created with. acpx's controls pin it with
    /// `applyModelSelection` — a model option through `applyConfigOptionSelection` — and
    /// its reconnect puts the model back before the saved options, since an option can
    /// depend on the model. Requests and record are acpx 0.19.1's for the same steps.
    @Test(.enabled(if: mockPythonAvailable), arguments: [false, true])
    func aLaterSelectionIsTheOneReplayed(legacy: Bool) async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/model-agent.py")
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            var options = SessionAcpxState.SessionOptions()
            options.model = "m2"
            let record = try await SessionEngine.createSession(
                agentCommand: "/usr/bin/env MODEL_AGENT_LOG='\(log.path)' "
                    + (legacy ? "MODEL_AGENT_LEGACY=1 " : "") + "'\(python)' '\(fixture.path)'",
                cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll, authCredentials: [:],
                authPolicy: "skip", sessionOptions: options)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.setModel(sessionId: record.acpxRecordId, modelId: "m1")
            if !legacy {
                _ = try await daemon.setConfigOption(sessionId: record.acpxRecordId, configId: "effort", value: "high")
            }
            await daemon.evict(record.acpxRecordId)
            let selected = try #require(SessionStore.loadRecord(record.acpxRecordId)?.acpx)
            #expect(selected.sessionOptions?.model == "m1")
            #expect(selected.currentModelId == "m1")
            #expect(selected.desiredConfigOptions == (legacy ? nil : ["effort": "high"]))

            let before = Self.requests(log).count
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .runPrompt(sessionId: record.acpxRecordId, text: "hi")
            let replayed = legacy
                ? ["session/set_model m1"]
                : ["session/set_config_option model=m1", "session/set_config_option effort=high"]
            #expect(Array(Self.requests(log).dropFirst(before)) == ["session/new"] + replayed + ["session/prompt"])
            // What the replay leaves on the record is the last reply's: the option replayed
            // after the model keeps its value, where the model's reply still said `low`.
            let restored = try #require(SessionStore.loadRecord(record.acpxRecordId)?.acpx)
            #expect(restored.sessionOptions?.model == "m1")
            if !legacy {
                #expect(restored.desiredConfigOptions == ["effort": "high"])
                guard case .array(let reported)? = restored.configOptions,
                      case .object(let effort)? = reported.last
                else {
                    Issue.record("expected the options the replay's last reply reported")
                    return
                }
                #expect(effort["currentValue"] == .string("high"))
            }
        }
    }

    /// A record an earlier SwiftACP wrote: created with `--model m2`, then switched by
    /// `set model m1` when that saved `m1` as the model's option and left the pin at
    /// `m2`. The later choice is the one put back, and pinned from then on.
    @Test(.enabled(if: mockPythonAvailable))
    func anOlderRecordsLaterSelectionWinsOverItsPin() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/model-agent.py")
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            var options = SessionAcpxState.SessionOptions()
            options.model = "m2"
            var record = try await SessionEngine.createSession(
                agentCommand: "/usr/bin/env MODEL_AGENT_LOG='\(log.path)' '\(python)' '\(fixture.path)'",
                cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll, authCredentials: [:],
                authPolicy: "skip", sessionOptions: options)
            // What the earlier `set model m1` left: the pin untouched, `m1` saved as an option.
            var acpx = try #require(record.acpx)
            acpx.desiredConfigOptions = ["model": "m1"]
            acpx.currentModelId = "m1"
            record.acpx = acpx
            try SessionStore.writeRecord(record)

            let before = Self.requests(log).count
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .runPrompt(sessionId: record.acpxRecordId, text: "hi")
            #expect(Array(Self.requests(log).dropFirst(before))
                == ["session/new", "session/set_config_option model=m1", "session/prompt"])
            let migrated = try #require(SessionStore.loadRecord(record.acpxRecordId)?.acpx)
            #expect(migrated.sessionOptions?.model == "m1")
            #expect(migrated.desiredConfigOptions == nil)
        }
    }

    /// An older record keeps its model only as the model option's saved value. Put back,
    /// that value is resolved with the adapter's rules, as `--model` is — here Cursor's
    /// alias rule, `gpt-5` for the advertised `gpt-5[thinking]`.
    @Test(.enabled(if: mockPythonAvailable))
    func aSavedModelOptionIsResolvedWithTheAdaptersRules() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/model-agent.py")
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            // Named `cursor-agent`, so the adapter's alias rule applies.
            let wrapper = ACPXPaths.baseDir.appendingPathComponent("cursor-agent")
            try """
                #!/bin/sh
                exec /usr/bin/env MODEL_AGENT_LOG='\(log.path)' MODEL_AGENT_MODELS='m1,gpt-5[thinking]' \
                  '\(python)' '\(fixture.path)'

                """.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            var record = try await SessionEngine.createSession(
                agentCommand: wrapper.path, cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll,
                authCredentials: [:], authPolicy: "skip")
            var acpx = try #require(record.acpx)
            acpx.desiredConfigOptions = ["model": "gpt-5"]
            record.acpx = acpx
            try SessionStore.writeRecord(record)

            let before = Self.requests(log).count
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .runPrompt(sessionId: record.acpxRecordId, text: "hi")
            #expect(Array(Self.requests(log).dropFirst(before))
                == ["session/new", "session/set_config_option model=gpt-5[thinking]", "session/prompt"])
        }
    }

    /// A session the reconnect started in place of the old one is asked for the pinned
    /// model through the control it advertises: here a model option, where the old one
    /// had a legacy model list.
    @Test(.enabled(if: mockPythonAvailable))
    func theReplacementsOwnControlCarriesTheModel() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/model-agent.py")
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            let agent = "/usr/bin/env MODEL_AGENT_LOG='\(log.path)' "
            var options = SessionAcpxState.SessionOptions()
            options.model = "m2"
            var record = try await SessionEngine.createSession(
                agentCommand: agent + "MODEL_AGENT_LEGACY=1 '\(python)' '\(fixture.path)'",
                cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll, authCredentials: [:],
                authPolicy: "skip", sessionOptions: options)
            #expect(record.acpx?.modelControl == "legacy_set_model")
            // The adapter changed how it offers models since.
            record.agentCommand = agent + "'\(python)' '\(fixture.path)'"
            record.agentArgv = nil
            try SessionStore.writeRecord(record)
            let before = Self.requests(log).count
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .runPrompt(sessionId: record.acpxRecordId, text: "hi")
            #expect(Array(Self.requests(log).dropFirst(before))
                == ["session/new", "session/set_config_option model=m2", "session/prompt"])
        }
    }

    /// Model ids are the keys of `available_model_names`, and go to disk as they are.
    @Test func modelNamesKeepTheirIdsOnDisk() async throws {
        try await withIsolatedStore {
            var record = SessionRecord(
                acpxRecordId: "rec-names", acpSessionId: "rec-names", agentCommand: "a", cwd: "/",
                createdAt: "2026-09-24T00:00:00.000Z", lastUsedAt: "2026-09-24T00:00:00.000Z")
            var acpx = SessionAcpxState()
            acpx.availableModelNames = ["GPT_4o": "Big", "claude-opus": "Opus"]
            record.acpx = acpx
            try SessionStore.writeRecord(record)
            #expect(SessionStore.loadRecord("rec-names")?.acpx?.availableModelNames
                == ["GPT_4o": "Big", "claude-opus": "Opus"])
            let file = try String(contentsOf: ACPXPaths.sessionRecordPath("rec-names"), encoding: .utf8)
            #expect(file.contains("\"GPT_4o\""))
        }
    }
}
