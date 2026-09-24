@testable import ACPXCore
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
    }

    /// Creates a session on the model fixture with `model` requested, returning the
    /// record it wrote and the session requests the agent received.
    private func create(legacy: Bool = false, model: String?) async throws -> Created {
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
