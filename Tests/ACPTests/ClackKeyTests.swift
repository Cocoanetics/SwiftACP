@testable import acpx
import Foundation
import Testing

/// The wizard's prompts read keys as Node's readline reads them for clack (#294).
/// `Fixtures/skill-wizard/readline-keys.json` holds what Node 25.9's readline made of each input,
/// written at once (`readline-keys.mjs` records it): the text it passed on, the key's name and its
/// whole sequence.
struct ClackKeyTests {
    struct Case: Decodable {
        let input: [UInt8]
        /// Each key's text, name and sequence.
        let keys: [[String?]]
    }

    struct Key: Equatable, CustomStringConvertible {
        let text: String?
        let name: String?
        let sequence: String?

        var description: String { "\([text, name, sequence].map { $0.debugDescription })" }
    }

    /// The same keys, from the input written to a pipe and the pipe closed.
    @Test func keysAreReadAsReadlineReadsThem() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/skill-wizard/readline-keys.json")
        struct Recording: Decodable { let cases: [Case] }
        let cases = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url)).cases
        #expect(cases.count > 80)
        for recorded in cases {
            #expect(read(recorded.input) == recorded.keys.map(Self.expected), "\(recorded.input)")
        }
    }

    /// A key as readline names it — except an escape code's name, which the wizard only needs for
    /// an arrow: no prompt reacts to `f1`, `delete` or `paste-start`.
    static func expected(_ key: [String?]) -> Key {
        let sequence = key.count > 2 ? key[2] : nil
        let escapeCode = ["\u{1B}[", "\u{1B}O", "\u{1B}\u{1B}[", "\u{1B}\u{1B}O"]
            .contains { sequence?.hasPrefix($0) == true }
        let name = key.count > 1 ? key[1] : nil
        let arrow = ["up", "down", "left", "right"].contains(name ?? "")
        return Key(text: key.first ?? nil, name: escapeCode && !arrow ? nil : name, sequence: sequence)
    }

    private func read(_ input: [UInt8]) -> [Key] {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return [] }
        defer { close(descriptors[0]) }
        _ = input.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }
        close(descriptors[1])
        let terminal = ClackTerminal(input: descriptors[0], output: -1)
        var keys: [Key] = []
        while let key = terminal.readKey() {
            keys.append(Key(text: key.text, name: key.name, sequence: key.sequence))
        }
        return keys
    }
}
