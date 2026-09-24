@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// How a session record is written: acpx's `serializeSessionRecordForDisk`, printed as
/// `JSON.stringify(…, null, 2)` with a newline (#85). The parser fixture holds, for each
/// record acpx takes, the exact file acpx 0.19.1 wrote for it (`disk`).
struct SessionRecordSerializerTests {
    private struct Case: Decodable {
        let name: String
        let raw: String
        let parsed: String?
        let disk: String?
    }

    private static let cases: [Case] = {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/acpx-record-parse.json")
        return (try? JSONDecoder().decode([Case].self, from: Data(contentsOf: fixture))) ?? []
    }()

    /// acpx's in-memory record serialized as acpx serializes it is acpx's file, byte for
    /// byte.
    @Test func aRecordIsSerializedAsAcpxSerializesIt() throws {
        let written = Self.cases.filter { $0.parsed != nil && $0.disk != nil }
        #expect(written.count == 75)
        for testCase in written {
            let text = try #require(testCase.parsed)
            let parsed = try #require(WireJSON(parsing: Data(text.utf8)))
            let disk = SessionRecordSerializer.forDisk(parsed, storedAcpx: nil).stringified(indent: 2) + "\n"
            #expect(disk == testCase.disk, "\(testCase.name)")
        }
    }

    /// And from the file itself — read as acpx reads it — as well. The fixture was made
    /// with `HOME=/ACPX-HOME`, so a default event log names that home's sessions
    /// directory; the test puts its own store's in its place.
    @Test func aStoredRecordIsWrittenBackAsAcpxWritesIt() async throws {
        try await withIsolatedStore {
            let sessionsDir = ACPXPaths.sessionsDir.path
            for testCase in Self.cases where testCase.disk != nil {
                let raw = try #require(WireJSON(parsing: Data(testCase.raw.utf8)))
                let parsed = try #require(SessionRecordParser.parse(raw), "\(testCase.name)")
                let disk = SessionRecordSerializer.forDisk(parsed, storedAcpx: nil).stringified(indent: 2) + "\n"
                let expected = testCase.disk?.replacingOccurrences(of: "/ACPX-HOME/.acpx/sessions", with: sessionsDir)
                #expect(disk == expected, "\(testCase.name)")
            }
        }
    }

    /// What a record read into SwiftACP's model and written back loses, besides SwiftACP's
    /// own `acpx` fields, which it adds: what the model cannot hold.
    private static let beyondTheModel: [String: String] = [
        "integers beyond Int": "a number the model holds as an Int",
        "integers at 2^63": "a number the model holds as an Int",
        "acpx max turns beyond Int": "a number the model holds as an Int",
        "protocol version fractional": "a number the model holds as an Int",
        "name with a lone surrogate": "a Swift string has no lone surrogate",
        "variants after a wrong-typed one": "the model holds one variant of a message's content",
        "acpx not an object": "SwiftACP keeps its restrictions at their tightest",
        "acpx null": "SwiftACP keeps its restrictions at their tightest"
    ]

    /// A record read into the model and written back is the file acpx writes for it,
    /// SwiftACP's own `acpx` fields aside: each value where the record had it, as acpx
    /// keeps what it read, and `null` where it was `null`.
    @Test func aRecordReadIsWrittenBackAsAcpxWritesIt() async throws {
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.sessionsDir, withIntermediateDirectories: true)
            let sessionsDir = ACPXPaths.sessionsDir.path
            let stored = ACPXPaths.sessionsDir.appendingPathComponent("stored.json")
            let written = Self.cases.filter { $0.disk != nil && Self.beyondTheModel[$0.name] == nil }
            #expect(written.count == 67)
            for testCase in written {
                try Data(testCase.raw.utf8).write(to: stored)
                let record = try #require(SessionStore.readRecord(at: stored), "\(testCase.name)")
                try SessionStore.writeRecord(record)
                let url = ACPXPaths.sessionRecordPath(record.acpxRecordId)
                let text = try String(contentsOf: url, encoding: .utf8)
                let file = try #require(WireJSON(parsing: Data(text.utf8)))
                let acpxFields = file["acpx"].map {
                    file.replacing("acpx", with: $0.removing("mcp_servers").removing("client_capabilities"))
                } ?? file
                let expected = testCase.disk?.replacingOccurrences(of: "/ACPX-HOME/.acpx/sessions", with: sessionsDir)
                #expect(acpxFields.stringified(indent: 2) + "\n" == expected, "\(testCase.name)")
                #expect(text == file.stringified(indent: 2) + "\n")
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// SwiftACP's own `acpx` fields, which acpx does not read, follow acpx's.
    @Test func swiftACPsOwnFieldsFollowAcpxs() throws {
        let raw = try #require(WireJSON(parsing: Data(#"""
            {"schema":"acpx.session.v1","acpx_record_id":"r","acp_session_id":"s","agent_command":"a","cwd":"/w",
            "created_at":"t","last_used_at":"t","last_seq":0,"event_log":{"active_path":"/p","segment_count":1,
            "max_segment_bytes":1,"max_segments":1,"last_write_at":null,"last_write_error":null},"closed":false,
            "messages":[],"updated_at":"t","cumulative_token_usage":{},"request_token_usage":{},
            "acpx":{"mcp_servers":[],"current_mode_id":"plan"}}
            """#.utf8)))
        let parsed = try #require(SessionRecordParser.parse(raw))
        let acpx = try #require(SessionRecordSerializer.forDisk(parsed, storedAcpx: raw["acpx"])["acpx"])
        #expect(acpx.stringified == #"{"current_mode_id":"plan","mcp_servers":[]}"#)
    }
}
