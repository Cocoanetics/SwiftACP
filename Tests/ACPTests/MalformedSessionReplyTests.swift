@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Session replies whose members the ACP schema would not take are taken as acpx 0.19.3
/// takes them. Its ACP SDK checks no reply, so acpx records `configOptions` as the agent
/// sent them — `null` as an empty list, and nothing JavaScript reads as false — reads
/// model state only from a list, and never reads `modes`. A `null` load reports nothing,
/// and a `null` option reply acknowledges. Where acpx fails with a `TypeError` instead
/// (an option reply that is neither a list nor a string), SwiftACP carries on.
///
/// Each test reads the record before the daemon lets the agent go: it records the agent's
/// exit on the record it reads back, as acpx's owner does at shutdown
/// (`resolveSessionRecord`), and a record read back has no options that are no list.
@Suite(.serialized) struct MalformedSessionReplyTests {
    private static let model: JSONValue = .object([
        "id": .string("model"), "type": .string("select"), "category": .string("model"), "name": .string("Model"),
        "currentValue": .string("m1"),
        "options": .array([
            .object(["value": .string("m1"), "name": .string("One")]),
            .object(["value": .string("m2"), "name": .string("Two")])
        ])
    ])

    /// A session created on the model fixture with `environment` set (`NAME=json` pairs,
    /// each value quoted for the command line), and its id.
    private func session(_ environment: [String: String]) async throws -> String {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/model-agent.py")
        let variables = environment.map { "\($0.key)='\($0.value)'" }.joined(separator: " ")
        let record = try await SessionEngine.createSession(
            agentCommand: "/usr/bin/env \(variables) '\(python)' '\(fixture.path)'", cwd: NSTemporaryDirectory(),
            name: nil, permission: .approveAll, authCredentials: [:], authPolicy: "skip", sessionOptions: nil)
        return record.acpxRecordId
    }

    /// The record's `acpx` block as its file holds it.
    private func written(_ id: String) throws -> [String: JSONValue] {
        let data = try Data(contentsOf: ACPXPaths.sessionRecordPath(id))
        guard case .object(let file) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let acpx)? = file["acpx"]
        else { throw POSIXError(.EINVAL) }
        return acpx
    }

    private func json(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @Test(.enabled(if: mockPythonAvailable), arguments: [
        JSONValue.string("oops"), .integer(5), .object(["a": .integer(1)]), .bool(true)
    ])
    func optionsThatAreNoListAreRecordedAsSent(_ options: JSONValue) async throws {
        try await withIsolatedStore {
            let reply = try json(.object(["configOptions": options]))
            let acpx = try written(try await session(["MODEL_AGENT_NEW_REPLY": reply]))
            #expect(acpx["config_options"] == options)
            #expect(acpx["current_model_id"] == nil)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aNullListIsAnEmptyOne() async throws {
        try await withIsolatedStore {
            let acpx = try written(try await session(["MODEL_AGENT_NEW_REPLY": #"{"configOptions":null}"#]))
            #expect(acpx["config_options"] == .array([]))
        }
    }

    /// acpx's `applyConfigOptionsToRecord` returns early for these (`if (!configOptions)`).
    @Test(.enabled(if: mockPythonAvailable), arguments: [JSONValue.string(""), .integer(0), .bool(false)])
    func optionsJavaScriptReadsAsFalseAreNotRecorded(_ options: JSONValue) async throws {
        try await withIsolatedStore {
            let reply = try json(.object(["configOptions": options]))
            let acpx = try written(try await session(["MODEL_AGENT_NEW_REPLY": reply]))
            #expect(acpx["config_options"] == nil)
        }
    }

    /// Written as they are, though acpx's parser keeps only a list of objects, so a record
    /// read back has none.
    @Test(.enabled(if: mockPythonAvailable))
    func entriesThatAreNoObjectsAreWrittenToo() async throws {
        try await withIsolatedStore {
            let options: JSONValue = .array([Self.model, .string("str"), .null])
            let id = try await session(["MODEL_AGENT_NEW_REPLY": try json(.object(["configOptions": options]))])
            let acpx = try written(id)
            #expect(acpx["config_options"] == options)
            #expect(acpx["current_model_id"] == .string("m1"))
            #expect(SessionStore.loadRecord(id)?.acpx?.configOptions == nil)
        }
    }

    @Test(.enabled(if: mockPythonAvailable), arguments: [
        #""oops""#, #"{"availableModes":[{"id":"plan","name":"Plan"}]}"#, #"{"currentModeId":"plan"}"#
    ])
    func modesTheSchemaWouldNotTakeFailNothing(_ modes: String) async throws {
        try await withIsolatedStore {
            let acpx = try written(try await session(["MODEL_AGENT_NEW_REPLY": #"{"modes":\#(modes)}"#]))
            #expect(acpx["current_model_id"] == .string("m1"))
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aModelReplyThatIsNoListIsRecordedAsSent() async throws {
        try await withIsolatedStore {
            let id = try await session(["MODEL_AGENT_SET_RESULT": #"{"configOptions":"oops"}"#])
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.setModel(sessionId: id, modelId: "m2")
            let acpx = try written(id)
            await daemon.releaseAll()
            #expect(acpx["config_options"] == .string("oops"))
            #expect(acpx["current_model_id"] == .string("m2"))
            #expect(acpx["model_control"] == nil)
            #expect(acpx["session_options"] == .object(["model": .string("m2")]))
        }
    }

    /// acpx walks a string reply's characters for the selections it reports, finding
    /// none, and counts its UTF-16 code units as the options.
    @Test(.enabled(if: mockPythonAvailable))
    func anOptionReplyThatIsAStringIsCountedAsAcpxCountsIt() async throws {
        try await withIsolatedStore {
            let id = try await session(["MODEL_AGENT_SET_RESULT": #"{"configOptions":"oops"}"#])
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let result = try await daemon.setConfigOption(sessionId: id, configId: "effort", value: "high")
            let acpx = try written(id)
            let record = try #require(SessionStore.loadRecord(id))
            await daemon.releaseAll()
            #expect(ControlCommand.optionCount(ControlCommand.reportedOptions(result, record: record)) == 4)
            #expect(acpx["config_options"] == .string("oops"))
            #expect(acpx["desired_config_options"] == nil)
        }
    }

    /// Here acpx fails with `configOptions is not iterable`.
    @Test(.enabled(if: mockPythonAvailable))
    func anOptionReplyThatIsNeitherAListNorAStringCarriesOn() async throws {
        try await withIsolatedStore {
            let id = try await session(["MODEL_AGENT_SET_RESULT": #"{"configOptions":5}"#])
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let result = try await daemon.setConfigOption(sessionId: id, configId: "effort", value: "high")
            let acpx = try written(id)
            await daemon.releaseAll()
            #expect(result.rawConfigOptions == .integer(5))
            #expect(acpx["config_options"] == .integer(5))
            #expect(acpx["desired_config_options"] == nil)
        }
    }

    /// acpx reads a `null` reply's `configOptions` as undefined for a model; for any other
    /// option it fails with a `TypeError`.
    @Test(.enabled(if: mockPythonAvailable))
    func aNullReplyAcknowledges() async throws {
        try await withIsolatedStore {
            let id = try await session(["MODEL_AGENT_SET_RESULT": "null"])
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.setModel(sessionId: id, modelId: "m2")
            let result = try await daemon.setConfigOption(sessionId: id, configId: "effort", value: "high")
            let record = try #require(SessionStore.loadRecord(id))
            await daemon.releaseAll()
            #expect(result.rawConfigOptions == nil)
            #expect(record.acpx?.currentModelId == "m2")
            #expect(record.acpx?.desiredConfigOptions == ["effort": "high"])
            guard case .array(let options)? = record.acpx?.configOptions else {
                Issue.record("the catalog is gone")
                return
            }
            #expect(options.map { $0.dictionaryValue?["currentValue"] } == [.string("m2"), .string("high")])
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aLoadReplyWithOptionsThatAreNoListIsRecordedAsSent() async throws {
        try await withIsolatedStore {
            let id = try await session([
                "MODEL_AGENT_LOAD": "1", "MODEL_AGENT_LOAD_RESULT": #"{"configOptions":"oops"}"#
            ])
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.runPrompt(sessionId: id, text: "hi")
            let acpx = try written(id)
            await daemon.releaseAll()
            #expect(acpx["config_options"] == .string("oops"))
            #expect(acpx["current_model_id"] == nil)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aNullLoadReplyReportsNothing() async throws {
        try await withIsolatedStore {
            let id = try await session(["MODEL_AGENT_LOAD": "1", "MODEL_AGENT_LOAD_RESULT": "null"])
            let before = try written(id)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.runPrompt(sessionId: id, text: "hi")
            let acpx = try written(id)
            await daemon.releaseAll()
            #expect(acpx["config_options"] == before["config_options"])
            #expect(acpx["current_model_id"] == .string("m1"))
        }
    }

    /// A `null` legacy model list is one the reply has (`hasResponseField`): with no model
    /// option to go by, the model state goes, and the options stay.
    @Test(.enabled(if: mockPythonAvailable))
    func aNullModelListClearsTheModelState() async throws {
        try await withIsolatedStore {
            let id = try await session(["MODEL_AGENT_LOAD": "1", "MODEL_AGENT_LOAD_RESULT": #"{"models":null}"#])
            let before = try written(id)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.runPrompt(sessionId: id, text: "hi")
            let acpx = try written(id)
            await daemon.releaseAll()
            #expect(acpx["config_options"] == before["config_options"])
            #expect(acpx["current_model_id"] == nil)
            #expect(acpx["model_control"] == nil)
        }
    }
}
