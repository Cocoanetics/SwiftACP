@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// acpx's command line is commander 15's: positional options on every command, the
/// agent commands passing their prompts through, no excess arguments (#72). Every case
/// in the fixture was run through npm acpx 0.19.1 with a preload that prints, in place of
/// running the command, what commander parsed — the command path, the arguments, and
/// each level's options as given. The rest — errors, help, version — are acpx's own
/// output, with the cwd shown as `<cwd>`.
///
/// Serialized because the tests redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct CommanderTests {
    private struct Case: Decodable {
        let args: [String]
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private struct Oracle: Decodable {
        struct Parsed: Decodable {
            struct Level: Decodable {
                let name: String
                let options: [[String?]]
            }

            let path: [String]
            let args: [String]
            let levels: [Level]
        }

        let parsed: Parsed
    }

    private static func cases() throws -> [Case] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/acpx-argv-parse.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixture))
    }

    /// The fixture's config: one agent of its own, `mine`.
    private static func withFixtureConfig(_ body: () throws -> Void) async throws {
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            try Data(#"{"agents":{"mine":{"command":"x"}}}"#.utf8).write(to: ACPXPaths.globalConfigPath)
            try body()
        }
    }

    @Test func parsesWhatAcpxParsesAsItParsesIt() async throws {
        let cases = try Self.cases()
        #expect(cases.count > 250)
        try await Self.withFixtureConfig {
            let config = try ConfigLoader.load(cwd: physicalCWD())
            for testCase in cases {
                guard let oracle = try? JSONDecoder().decode(Oracle.self, from: Data(testCase.stdout.utf8)) else {
                    continue
                }
                let label = testCase.args.debugDescription
                let agents = CommandTree.agentNames(config: config, arguments: testCase.args)
                let outcome = try Commander.parse(testCase.args, root: CommandTree.acpx(agents: agents))
                guard case .run(let levels, let arguments) = outcome else {
                    Issue.record("\(label): \(outcome) where acpx ran \(oracle.parsed.path)")
                    continue
                }
                #expect(levels.map(\.spec.name) == oracle.parsed.path, "\(label)")
                #expect(arguments == oracle.parsed.args, "\(label)")
                let given = levels.map { $0.events.map { [$0.name, $0.value] } }
                #expect(given == oracle.parsed.levels.map(\.options), "\(label)")
            }
        }
    }

    /// Everything the parse refuses or answers itself, printed as acpx prints it.
    @Test func reportsWhatAcpxReportsInItsWords() async throws {
        let cases = try Self.cases()
        try await Self.withFixtureConfig {
            let cwd = physicalCWD()
            for testCase in cases where !testCase.stdout.contains(#"{"parsed":"#) {
                let capture = Console.Capture()
                let code = Console.$capture.withValue(capture) { runCommandLine(testCase.args) }
                let label = testCase.args.debugDescription
                #expect(code == testCase.exitCode, "\(label)")
                // SwiftACP answers `--version` with its own version.
                let stdout = testCase.stdout == "0.19.1\n" ? ACPVersion.current + "\n" : testCase.stdout
                #expect(capture.out.replacingOccurrences(of: cwd, with: "<cwd>") == stdout, "\(label)")
                #expect(capture.err.replacingOccurrences(of: cwd, with: "<cwd>") == testCase.stderr, "\(label)")
            }
        }
    }

    @Test func suggestsAsCommanderSuggests() {
        #expect(Commander.suggestSimilar("--locall", ["--local", "--cursor", "--help"]) == "\n(Did you mean --local?)")
        #expect(Commander.suggestSimilar("--curso", ["--local", "--cursor"]) == "\n(Did you mean --cursor?)")
        #expect(Commander.suggestSimilar("lisst", ["list", "new"]) == "\n(Did you mean list?)")
        #expect(Commander.suggestSimilar("--x", ["--y"]).isEmpty)
        #expect(Commander.suggestSimilar("--tai", ["--tail", "--tag"]) == "\n(Did you mean one of --tag, --tail?)")
    }

    @Test func negativeNumbersAreCommandersShape() {
        for number in ["-5", "-0", "-5.5", "-.5", "-5e3", "-5e+3", "-5E3"] where number != "-5E3" {
            #expect(Commander.isNegativeNumber(number), "\(number)")
        }
        for other in ["-", "-.", "-5.", "-e3", "-5e", "-x", "--5", "-5E3", "-５"] {
            #expect(!Commander.isNegativeNumber(other), "\(other)")
        }
    }
}
