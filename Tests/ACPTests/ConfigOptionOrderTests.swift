@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// A session's config options written in the order acpx 0.19.3 writes them (#175): those a
/// `config_option_update` gave in the order its SDK builds them, and an option changed in place
/// keeping its members' places.
@Suite struct ConfigOptionOrderTests {
    /// The SDK builds an option as zod intersects its kind with the rest: `currentValue`,
    /// `options`, `type`, then `id`, `name`, `description`, `category`, `_meta`; a select option
    /// `value`, `name`, `description`, `_meta`; a group `group`, `name`, `options`, `_meta`.
    @Test func anUpdatesOptionsAreInTheSchemasOrder() throws {
        let update = try #require(WireJSON(parsing: """
            {"configOptions": [
              {"_meta": {"k": 1}, "category": "model", "description": "d", "name": "Model", "id": "model",
               "type": "select", "options": [{"_meta": null, "description": "fast", "name": "One", "value": "m1"}],
               "currentValue": "m1"},
              {"name": "Grouped", "id": "g", "type": "select", "currentValue": "a",
               "options": [{"options": [{"name": "A", "value": "a"}], "name": "Group", "group": "one"}]},
              {"id": "flag", "name": "Flag", "type": "boolean", "currentValue": true}
            ]}
            """)).jsonValue
        let options = try #require(ConfigOptionSchema.options(of: update))
        let ordered = ConfigOptionSchema.ordered(options)
        #expect(Self.keys(ordered, 0)
            == ["currentValue", "options", "type", "id", "name", "description", "category", "_meta"])
        #expect(Self.keys(ordered[0]?["options"], 0) == ["value", "name", "description", "_meta"])
        #expect(Self.keys(ordered[1]?["options"], 0) == ["group", "name", "options"])
        #expect(Self.keys(ordered[1]?["options"]?[0]?["options"], 0) == ["value", "name"])
        #expect(Self.keys(ordered, 2) == ["currentValue", "type", "id", "name"])
    }

    /// An update's `_meta` — a zod record, which keeps the agent's order — is as the agent wrote
    /// it, all the way down, in an option and in a select option, while the members the schema
    /// builds are in its order (#243 review).
    @Test func anUpdatesMetaKeepsTheAgentsOrder() throws {
        let written = try #require(WireJSON(parsing: #"{"configOptions": [{"_meta": {"z": 1, "a": {"y": 2, "b": 3}}, "#
            + #""name": "Model", "id": "model", "type": "select", "#
            + #""options": [{"_meta": {"q": 1, "c": 2}, "name": "One", "value": "m1"}], "currentValue": "m1"}]}"#))
        let options = try #require(ConfigOptionSchema.options(of: written.jsonValue))
        let ordered = ConfigOptionSchema.ordered(options, as: written["configOptions"])
        #expect(ordered.stringified == #"[{"currentValue":"m1","options":[{"value":"m1","name":"One","#
            + #""_meta":{"q":1,"c":2}}],"type":"select","id":"model","name":"Model","#
            + #""_meta":{"z":1,"a":{"y":2,"b":3}}}]"#)
    }

    /// Options written in the order they came in keep it though changed in place — a new
    /// selection — each matched by its `id`, a select option by its `value`; one the order does
    /// not know has its members sorted.
    @Test func optionsChangedInPlaceKeepTheirMembersPlaces() throws {
        let template = try #require(WireJSON(parsing: """
            [{"id": "effort", "currentValue": "low", "options": [{"value": "low", "name": "Low"}]},
             {"id": "model", "currentValue": "m1", "options": [{"value": "m1", "name": "One"}]}]
            """))
        let current: JSONValue = .array([
            .object(["id": .string("model"), "currentValue": .string("m2"),
                     "options": .array([.object(["value": .string("m1"), "name": .string("One")])])]),
            .object(["zeta": .string("z"), "id": .string("new"), "alpha": .string("a")])
        ])
        let written = ConfigOptionSchema.inOrder(current, of: template)
        #expect(Self.keys(written, 0) == ["id", "currentValue", "options"])
        #expect(written[0]?["currentValue"]?.stringValue == "m2")
        #expect(Self.keys(written[0]?["options"], 0) == ["value", "name"])
        #expect(Self.keys(written, 1) == ["alpha", "id", "zeta"])
    }

    /// Every object in an option takes its counterpart's order — its `_meta`, and whatever it
    /// holds — as read back options keep what they were read with (#243 review).
    @Test func nestedObjectsKeepTheirOrder() throws {
        let read = #"[{"id":"m","_meta":{"z":1,"a":{"y":2,"b":3}},"currentValue":"x","#
            + #""options":[{"value":"x","_meta":{"q":1,"c":2},"name":"X"}]}]"#
        let template = try #require(WireJSON(parsing: read))
        let current = try JSONDecoder().decode(JSONValue.self, from: Data(read.replacingOccurrences(
            of: #""currentValue":"x""#, with: #""currentValue":"y""#).utf8))
        let written = ConfigOptionSchema.inOrder(current, of: template)
        let changed = read.replacingOccurrences(of: #""currentValue":"x""#, with: #""currentValue":"y""#)
        #expect(written.stringified == changed)
    }

    /// Options with no `id`, or one another has too, have only their place to go by, as do
    /// select options without a unique `value` (#243 review).
    @Test func entriesWithoutAUniqueKeyKeepTheirPlaces() throws {
        let read = #"[{"b":1,"a":2},{"id":"x","d":1,"c":2},{"id":"x","f":1,"e":2},"#
            + #"{"id":"u","options":[{"value":"v","n":1,"m":2},{"value":"v","l":1,"k":2}]}]"#
        let template = try #require(WireJSON(parsing: read))
        let current = try JSONDecoder().decode(JSONValue.self, from: Data(read.utf8))
        #expect(ConfigOptionSchema.inOrder(current, of: template).stringified == read)
    }

    /// A record read back and written again keeps its options exactly as they were read.
    @Test func aRecordReadBackKeepsItsOptions() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            try SessionStore.writeRecord(SessionRecord(
                acpxRecordId: "opts", acpSessionId: "opts", agentCommand: "codex", cwd: "/tmp",
                createdAt: now, lastUsedAt: now))
            let path = ACPXPaths.sessionRecordPath("opts")
            let options = #"[{"type":"select","id":"m","_meta":{"z":1,"a":2},"name":"M","currentValue":"x","#
                + #""options":[{"name":"X","value":"x"}]},{"name":"No id","b":1,"a":2}]"#
            guard case .object(let members)? = WireJSON(parsing: try Data(contentsOf: path)) else {
                Issue.record("no record")
                return
            }
            let block = WireJSON.object([.init("config_options", try #require(WireJSON(parsing: options)))])
            let file = WireJSON.object(members.filter { $0.key != Array("acpx".utf16) } + [.init("acpx", block)])
            try Data((file.stringified(indent: 2) + "\n").utf8).write(to: path)
            let record = try #require(SessionStore.loadRecord("opts"))
            try SessionStore.writeRecord(record)
            let written = try #require(WireJSON(parsing: try Data(contentsOf: path)))
            #expect(written["acpx"]?["config_options"]?.stringified == options)
        }
    }

    /// A turn's `config_option_update` leaves its options in the record in the SDK's order, and
    /// a selection a reply only acknowledges changes them in place: what acpx 0.19.3 wrote for
    /// the same session, turn and `set model` (`model-agent.py`).
    @Test(.enabled(if: mockPythonAvailable))
    func aSessionsOptionsAreWrittenInAcpxsOrder() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let agent = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py").path
        let command = "/usr/bin/env MODEL_AGENT_PROMPT_OPTIONS=1 MODEL_AGENT_LOAD=1 MODEL_AGENT_EMPTY_REPLIES=1 "
            + "'\(python)' '\(agent)'"
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "hi")
            var options = try Self.writtenOptions(id)
            #expect(Self.keys(options, 0) == ["currentValue", "options", "type", "id", "name", "category"])
            #expect(Self.keys(options, 1) == ["currentValue", "options", "type", "id", "name"])
            #expect(Self.keys(options[0]?["options"], 0) == ["value", "name"])

            _ = try await daemon.setModel(sessionId: id, modelId: "m2")
            options = try Self.writtenOptions(id)
            #expect(options[0]?["currentValue"]?.stringValue == "m2")
            #expect(Self.keys(options, 0) == ["currentValue", "options", "type", "id", "name", "category"])
            #expect(Self.keys(options[0]?["options"], 0) == ["value", "name"])
            await daemon.releaseAll()
        }
    }

    /// A turn's `config_option_update` keeps each `_meta` as the agent wrote it, the members the
    /// schema builds in its order: what acpx 0.19.3 wrote for the same turn (#243 review).
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnsUpdateKeepsTheAgentsMetaOrder() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let agent = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py").path
        let options = #"[{"_meta":{"z":1,"a":{"y":2,"b":3}},"name":"Model","id":"model","type":"select","#
            + #""category":"model","options":[{"_meta":{"q":1,"c":2},"name":"M1","value":"m1"},"#
            + #"{"value":"m2","name":"M2"}],"currentValue":"m1"}]"#
        let command = "/usr/bin/env 'MODEL_AGENT_PROMPT_OPTIONS=\(options)' MODEL_AGENT_LOAD=1 '\(python)' '\(agent)'"
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "hi")
            await daemon.releaseAll()
            #expect(try Self.writtenOptions(id).stringified
                == #"[{"currentValue":"m1","options":[{"value":"m1","name":"M1","_meta":{"q":1,"c":2}},"#
                + #"{"value":"m2","name":"M2"}],"type":"select","id":"model","name":"Model","category":"model","#
                + #""_meta":{"z":1,"a":{"y":2,"b":3}}}]"#)
        }
    }

    /// The record's `acpx.config_options` as written.
    static func writtenOptions(_ id: String) throws -> WireJSON {
        let record = try #require(WireJSON(parsing: try Data(contentsOf: ACPXPaths.sessionRecordPath(id))))
        return try #require(record["acpx"]?["config_options"])
    }

    /// The member names of `list`'s item at `index`, in order.
    static func keys(_ list: WireJSON?, _ index: Int) -> [String] {
        guard case .object(let members)? = list?[index] else { return [] }
        return members.map { String(decoding: $0.key, as: UTF16.self) }
    }
}

extension WireJSON {
    /// The item at `index`, when this is an array that long.
    subscript(index: Int) -> WireJSON? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }
}
