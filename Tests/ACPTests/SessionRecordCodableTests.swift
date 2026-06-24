@testable import ACPXCore
import Foundation
import JSONFoundation
import Testing

/// Round-trip fidelity for the persisted session-record substructures, locking
/// down two parity bugs: agents advertise `available_commands` as bare strings
/// (codex) or objects (claude), and `tool_use.thought_signature` is persisted
/// present-but-null. Both must survive decode→encode without loss or reshaping.
struct SessionRecordCodableTests {
    // The on-disk record format is snake_case; the disk coders translate to/from
    // the camelCase models. Inputs/outputs here are snake_case (disk shape).
    private let decoder = recordDiskDecoder
    private let encoder = recordDiskEncoder

    private func reencode<T: Codable>(_ type: T.Type, _ json: String) throws -> JSONValue {
        let value = try decoder.decode(T.self, from: Data(json.utf8))
        // Re-parse the encoded bytes verbatim (plain decoder) to inspect disk keys.
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    // MARK: available_commands union (string | object)

    @Test func availableCommandsBareStringsPreserved() throws {
        let json = #"{"available_commands":["update-config","debug","simplify"]}"#
        let out = try reencode(SessionAcpxState.self, json)
        #expect(out == JSONValue.object(["available_commands": .array([
            .string("update-config"), .string("debug"), .string("simplify")
        ])]))
    }

    @Test func availableCommandsObjectsPreserved() throws {
        let json =
            #"{"available_commands":[{"name":"mcp","description":"List MCP tools.","has_input":false}]}"#
        let out = try reencode(SessionAcpxState.self, json)
        #expect(out == JSONValue.object(["available_commands": .array([
            .object(["name": .string("mcp"), "description": .string("List MCP tools."),
                     "has_input": .bool(false)])
        ])]))
    }

    @Test func availableCommandsMixedFormsPreserved() throws {
        let json = #"{"available_commands":["debug",{"name":"mcp"}]}"#
        let state = try decoder.decode(SessionAcpxState.self, from: Data(json.utf8))
        #expect(state.availableCommands?.count == 2)
        if case .bare(let s) = state.availableCommands?[0] { #expect(s == "debug") } else {
            Issue.record("expected bare string")
        }
        if case .detailed(let d) = state.availableCommands?[1] { #expect(d.name == "mcp") } else {
            Issue.record("expected detailed")
        }
    }

    // MARK: tool_use.thought_signature tri-state

    @Test func thoughtSignaturePresentNullPreserved() throws {
        let json =
            #"{"id":"t1","name":"ls","raw_input":"{}","input":{},"is_input_complete":true,"thought_signature":null}"#
        let out = try reencode(SessionToolUse.self, json)
        guard case .object(let obj) = out else { Issue.record("expected object"); return }
        // Present-but-null must remain present-and-null, not be dropped.
        #expect(obj["thought_signature"] == .null)
    }

    @Test func thoughtSignatureAbsentStaysAbsent() throws {
        let json = #"{"id":"t1","name":"ls","raw_input":"{}","is_input_complete":true}"#
        let out = try reencode(SessionToolUse.self, json)
        guard case .object(let obj) = out else { Issue.record("expected object"); return }
        #expect(obj["thought_signature"] == nil)
    }

    @Test func thoughtSignatureStringPreserved() throws {
        let json =
            #"{"id":"t1","name":"ls","raw_input":"{}","is_input_complete":true,"thought_signature":"sig-abc"}"#
        let out = try reencode(SessionToolUse.self, json)
        guard case .object(let obj) = out else { Issue.record("expected object"); return }
        #expect(obj["thought_signature"] == .string("sig-abc"))
    }
}
