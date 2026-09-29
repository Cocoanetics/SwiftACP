@testable import acpx
import Foundation
import Testing

/// The wizard wraps its frames as fast-wrap-ansi 0.2.2 wraps clack's (#294).
/// `Fixtures/skill-wizard/wrap-ansi.json` holds what `wrapAnsi(text, columns, { hard: true, trim:
/// false })` made of texts at widths down to below zero — a narrow terminal less a prefix
/// (`wrap-ansi.mjs` records it).
struct ClackWrapTests {
    struct Case: Decodable {
        let text: String
        let columns: Int
        let wrapped: String
    }

    @Test func textIsWrappedAsFastWrapAnsiWrapsIt() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/skill-wizard/wrap-ansi.json")
        struct Recording: Decodable { let cases: [Case] }
        let cases = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url)).cases
        #expect(cases.count == 72)
        for recorded in cases {
            let wrapped = ClackText.wrap(recorded.text, columns: recorded.columns)
            #expect(wrapped == recorded.wrapped, "\(recorded.text.debugDescription) at \(recorded.columns)")
        }
    }
}
