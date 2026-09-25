@testable import ACPXCore
import Foundation
import Testing

/// ``SessionRecordParser`` against acpx 0.19.3's own `parseSessionRecord`. Each fixture
/// case is a stored record, and what acpx's npm build made of it: `JSON.stringify` of
/// the parsed record, or `null` for one it rejects. The build is 0.19.1's with the one
/// change 0.19.3 made to `parse.ts`, #766's check of an image's `mime_type`.
///
/// The fixture was generated with `HOME=/ACPX-HOME`, so a default event log names that
/// home's sessions directory; the test puts its own store's in its place, holding the
/// store (``withIsolatedStore(_:)``) so no other test moves it meanwhile.
@Suite struct SessionRecordParserTests {
    struct Case: Decodable {
        let name: String
        let raw: String
        let parsed: String?
    }

    private static func cases() throws -> [Case] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/acpx-record-parse.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixture))
    }

    @Test func parsesEveryRecordAsAcpxDoes() async throws {
        let cases = try Self.cases()
        #expect(cases.count > 100)
        try await withIsolatedStore {
            let sessionsDir = ACPXPaths.sessionsDir.path
            for testCase in cases {
                let raw = try #require(WireJSON(parsing: Data(testCase.raw.utf8)), "\(testCase.name)")
                let expected = testCase.parsed?.replacingOccurrences(
                    of: "/ACPX-HOME/.acpx/sessions", with: sessionsDir)
                #expect(SessionRecordParser.parse(raw)?.stringified == expected, "\(testCase.name)")
            }
        }
    }
}
