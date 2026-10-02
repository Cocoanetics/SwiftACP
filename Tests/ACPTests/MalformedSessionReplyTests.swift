@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Session replies whose members the ACP schema would not take are taken as acpx 0.19.4
/// takes them. Its ACP SDK checks no reply, so acpx reads a reply's members off whatever the
/// agent sent — and reads `configOptions` only when it is a list (`normalizeResponseConfigOptions`,
/// `normalizeConfigOptionAcknowledgement`, openclaw/acpx#809): anything else a `session/new` or
/// load reply holds is not recorded, and an option reply holding one only acknowledges. Model
/// state is read only from a list, and `modes` never. A `null` load reports nothing, and a
/// `null` option reply acknowledges. acpx 0.19.3 recorded whatever JavaScript read as true, and
/// failed on most option replies that were no list with a `TypeError` (#201).
///
/// Each test reads the record before the daemon lets the agent go: it records the agent's
/// exit on the record it reads back, as acpx's owner does at shutdown
/// (`resolveSessionRecord`), and a record read back has no options that are no list.
@Suite(.serialized, .agentLane) struct MalformedSessionReplyTests {
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

    /// Each option's `currentValue`, in the catalog's order.
    private func currentValues(_ options: JSONValue?) -> [JSONValue?]? {
        options?.arrayValue?.map { $0.dictionaryValue?["currentValue"] }
    }

    /// acpx's `applyConfigOptionsToRecord` returns early for these (`if (!Array.isArray(configOptions))`),
    /// and reads no model state from them.
    @Test(.enabled(if: mockPythonAvailable), arguments: [
        JSONValue.string("oops"), .integer(5), .object(["a": .integer(1)]), .bool(true), .null, .string(""),
        .integer(0), .bool(false)
    ])
    func optionsThatAreNoListAreNotRecorded(_ options: JSONValue) async throws {
        try await withIsolatedStore {
            let reply = try json(.object(["configOptions": options]))
            let acpx = try written(try await session(["MODEL_AGENT_NEW_REPLY": reply]))
            #expect(acpx["config_options"] == nil)
            #expect(acpx["current_model_id"] == nil)
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

    /// The catalog stays, the model's option at the model set; acpx 0.19.3 recorded the string
    /// as the catalog and lost the model control.
    @Test(.enabled(if: mockPythonAvailable))
    func aModelReplyWhoseOptionsAreNoListAcknowledges() async throws {
        try await withIsolatedStore {
            let id = try await session(["MODEL_AGENT_SET_RESULT": #"{"configOptions":"oops"}"#])
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.setModel(sessionId: id, modelId: "m2")
            let acpx = try written(id)
            await daemon.releaseAll()
            #expect(currentValues(acpx["config_options"]) == [.string("m2"), .string("low")])
            #expect(acpx["current_model_id"] == .string("m2"))
            #expect(acpx["model_control"] == .string("config_option"))
            #expect(acpx["session_options"] == .object(["model": .string("m2")]))
        }
    }

    /// The daemon hands the CLI no options for such a reply, and `set` reports the record's
    /// (`printSetConfigOptionResultByFormat`). acpx 0.19.3 counted a string reply's characters,
    /// and failed on a number or an object with `configOptions is not iterable`.
    @Test(.enabled(if: mockPythonAvailable), arguments: [
        JSONValue.string("oops"), .integer(5), .object([:]), .null
    ])
    func anOptionReplyWhoseOptionsAreNoListAcknowledges(_ options: JSONValue) async throws {
        try await withIsolatedStore {
            let reply = try json(.object(["configOptions": options]))
            let id = try await session(["MODEL_AGENT_SET_RESULT": reply])
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let result = try await daemon.setConfigOption(sessionId: id, configId: "effort", value: "high")
            let acpx = try written(id)
            let record = try #require(SessionStore.loadRecord(id))
            await daemon.releaseAll()
            #expect(result.rawConfigOptions == nil)
            #expect(ControlCommand.optionCount(ControlCommand.reportedOptions(result, record: record)) == 2)
            #expect(currentValues(acpx["config_options"]) == [.string("m1"), .string("high")])
            #expect(acpx["desired_config_options"] == .object(["effort": .string("high")]))
        }
    }

    /// acpx reads a `null` reply as `{}` (`normalizeConfigOptionAcknowledgement`): an
    /// acknowledgement, for the model and for any other option.
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
            #expect(currentValues(record.acpx?.configOptions) == [.string("m2"), .string("high")])
        }
    }

    /// A load reply listing no options — none, `null`, or something that is no list — leaves
    /// the record's catalog and model state as they were (`configOptionsPresent` is false for
    /// all of them); acpx 0.19.3 recorded a string as the catalog, and `null` as an empty one.
    @Test(.enabled(if: mockPythonAvailable), arguments: [
        "null", #"{"configOptions":"oops"}"#, #"{"configOptions":null}"#, #"{"configOptions":5}"#
    ])
    func aLoadReplyListingNoOptionsLeavesTheRecord(_ reply: String) async throws {
        try await withIsolatedStore {
            let id = try await session(["MODEL_AGENT_LOAD": "1", "MODEL_AGENT_LOAD_RESULT": reply])
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
