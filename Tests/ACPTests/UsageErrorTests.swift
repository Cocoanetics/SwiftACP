@testable import ACPXCore
@testable import acpx
import Foundation
import Testing

/// How a bad command line is reported. commander frames a rejected option with
/// its help term, prints the command's full help after the message, and exits 1;
/// a *global* option belongs to the root command, so it shows the root help and
/// exits 2 with the message repeated. Every expectation here was captured from
/// npm acpx 0.19.1.
struct UsageErrorTests {
    // MARK: - The help term

    @Test func theTermIsCommandersFlagsPlusPlaceholder() {
        #expect(OptionSpec("file", short: "f", takesValue: true, value: "path").term
            == "-f, --file <path>")
        #expect(OptionSpec("config-option", takesValue: true, value: "key=value").term
            == "--config-option <key=value>")
        #expect(OptionSpec("verbose").term == "--verbose")
        #expect(OptionSpec("version", short: "V").term == "-V, --version")
    }

    /// A value option with no placeholder would print `--file` where acpx prints
    /// `-f, --file <path>`, so every one of them carries a `value:`.
    @Test func everyValueOptionCarriesAPlaceholder() throws {
        let specs = Flags.globalSpecs + Router.routingSpecs
        let missing = specs.filter { $0.takesValue && $0.value == nil }.map(\.long)
        #expect(missing.isEmpty, "value options without a placeholder: \(missing)")
    }

    // MARK: - Message shapes

    @Test func aMissingArgumentNamesTheOption() {
        let error = #expect(throws: UsageError.self) {
            try ArgScanner.scan(
                ["--file"], options: [OptionSpec("file", short: "f", takesValue: true, value: "path")])
        }
        #expect(error?.message == "option '-f, --file <path>' argument missing")
    }

    @Test func anUnknownOptionIsNamedAsGiven() {
        let error = #expect(throws: UsageError.self) {
            try ArgScanner.scan(["--bogus"], options: [])
        }
        #expect(error?.message == "unknown option '--bogus'")
    }

    /// The parser supplies only the reason; the scan knows which option carried
    /// the value, so it frames the rest.
    @Test func aRejectedValueIsFramedWithTheOptionAndTheValue() throws {
        let scan = try ArgScanner.scan(
            ["--config-option", "noequals"],
            options: [OptionSpec("config-option", takesValue: true, value: "key=value")])
        let error = #expect(throws: UsageError.self) {
            try scan.parsed("config-option", parseSessionConfigOptionAssignment)
        }
        #expect(error?.message == """
            option '--config-option <key=value>' argument 'noequals' is invalid. \
            Session config option must use "<key>=<value>" with non-empty parts
            """)
    }

    @Test func aRepeatedOptionFramesTheOffendingOccurrence() throws {
        let spec = OptionSpec("config-option", takesValue: true, repeats: true, value: "key=value")
        let scan = try ArgScanner.scan(
            ["--config-option", "a=1", "--config-option", "bad"], options: [spec])
        let error = #expect(throws: UsageError.self) {
            try scan.parsedAll("config-option", parseSessionConfigOptionAssignment)
        }
        #expect(error?.message.contains("argument 'bad' is invalid") == true)
    }

    // MARK: - Scope

    /// A global option is declared on commander's root, so its rejection is the
    /// root's — not that of whichever subcommand happened to follow it.
    @Test func aRejectedGlobalValueIsScopedToTheRoot() throws {
        let scan = try ArgScanner.scan(["--max-turns", "abc"], options: Flags.globalSpecs)
        let context = CommandContext(
            explicitAgent: nil, positionals: [], rawArgs: ["--max-turns", "abc"],
            config: try ConfigLoader.load(cwd: NSTemporaryDirectory()))
        let error = #expect(throws: UsageError.self) { try context.globalFlags(scan) }
        #expect(error?.scope == .root)
        #expect(error?.message == """
            option '--max-turns <count>' argument 'abc' is invalid. \
            Max turns must be a positive integer
            """)
    }

    @Test func aSubcommandsOwnOptionStaysScopedToIt() throws {
        let error = #expect(throws: UsageError.self) {
            try ArgScanner.scan(["--bogus"], options: [OptionSpec("file", takesValue: true, value: "path")])
        }
        #expect(error?.scope == .command)
    }

    // MARK: - Lenient routing

    /// The routing pre-pass only recovers the command path. If it threw, the error
    /// would arrive before the path was known and could not show the right help —
    /// so it skips what it does not recognize and lets the command's scan report it.
    @Test func theRoutingPassSkipsWhatItDoesNotRecognize() throws {
        let scan = try ArgScanner.scan(
            ["codex", "exec", "--bogus", "--also-unknown", "value", "hi"],
            options: Router.routingSpecs, lenient: true)
        #expect(scan.positionals.contains("codex"))
        #expect(scan.positionals.contains("exec"))
    }

    @Test func aMissingArgumentDoesNotStopTheRoutingPass() throws {
        let scan = try ArgScanner.scan(
            ["codex", "exec", "--file"], options: Router.routingSpecs, lenient: true)
        #expect(scan.positionals == ["codex", "exec"])
    }

    /// Strict scanning is unchanged: the same argv still fails when the command
    /// parses it for real.
    @Test func strictScanningStillRejectsBothCases() {
        #expect(throws: UsageError.self) {
            try ArgScanner.scan(["--bogus"], options: Router.routingSpecs)
        }
        #expect(throws: UsageError.self) {
            try ArgScanner.scan(["--file"], options: Router.routingSpecs)
        }
    }
}
