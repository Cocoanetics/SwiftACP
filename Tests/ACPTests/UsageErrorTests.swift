@testable import ACPXCore
@testable import acpx
import Foundation
import Testing

/// How a bad command line is reported. commander frames a rejected option with
/// its help term and prints the failing command's help after the message; a
/// subcommand's failure exits 1, the root's is acpx's usage error (exit 2). Every
/// expectation here was captured from npm acpx 0.19.1; `CommanderTests` checks the
/// whole corpus.
struct UsageErrorTests {
    private static let root = CommandTree.acpx(agents: ["codex"])

    private static func parseError(_ args: [String]) -> UsageError? {
        #expect(throws: UsageError.self) { try Commander.parse(args, root: root) }
    }

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
    @Test func everyValueOptionCarriesAPlaceholder() {
        func options(_ command: CommandSpec) -> [OptionSpec] {
            command.options + command.subcommands.flatMap(options)
        }
        let missing = options(Self.root).filter { $0.takesValue && $0.value == nil }.map(\.long)
        #expect(missing.isEmpty, "value options without a placeholder: \(missing)")
    }

    // MARK: - Message shapes

    @Test func aMissingArgumentNamesTheOption() {
        #expect(Self.parseError(["exec", "--file"])?.message == "option '-f, --file <path>' argument missing")
    }

    @Test func anUnknownOptionIsNamedAsGiven() {
        #expect(Self.parseError(["status", "--bogus"])?.message == "unknown option '--bogus'")
    }

    /// The parser supplies only the reason; the parse knows which option carried the
    /// value, so it frames the rest.
    @Test func aRejectedValueIsFramedWithTheOptionAndTheValue() {
        #expect(Self.parseError(["exec", "--config-option", "noequals", "hi"])?.message == """
            option '--config-option <key=value>' argument 'noequals' is invalid. \
            Session config option must use "<key>=<value>" with non-empty parts
            """)
    }

    @Test func aRepeatedOptionFramesTheOffendingOccurrence() {
        let error = Self.parseError(["exec", "--config-option", "a=1", "--config-option", "bad", "hi"])
        #expect(error?.message.contains("argument 'bad' is invalid") == true)
    }

    // MARK: - Scope

    /// A global option is declared on commander's root, so its rejection is the
    /// root's — not that of whichever subcommand follows it.
    @Test func aRejectedGlobalValueIsScopedToTheRoot() {
        let error = Self.parseError(["--max-turns", "abc", "status"])
        #expect(error?.scope == .root)
        #expect(error?.path == [])
        #expect(error?.message == """
            option '--max-turns <count>' argument 'abc' is invalid. \
            Max turns must be a positive integer
            """)
    }

    @Test func aSubcommandsOwnOptionStaysScopedToIt() {
        let error = Self.parseError(["codex", "exec", "--bogus"])
        #expect(error?.scope == .command)
        #expect(error?.path == ["codex", "exec"])
    }

    /// Options are positional: a global option after the command is not the root's,
    /// so the command refuses it as its own.
    @Test func aGlobalOptionAfterTheCommandIsTheCommandsUnknownOption() {
        let error = Self.parseError(["sessions", "list", "--cwd", "/b"])
        #expect(error?.message == "unknown option '--cwd'")
        #expect(error?.scope == .command)
        #expect(error?.path == ["sessions", "list"])
    }

    /// An agent's prompt passes through: flags after its first word are prompt text.
    @Test func anAgentsPromptKeepsItsFlags() throws {
        guard case .run(let levels, let arguments) = try Commander.parse(
            ["codex", "fix", "the", "--cwd", "bug"], root: Self.root)
        else {
            Issue.record("not a run")
            return
        }
        #expect(levels.map(\.spec.name) == ["acpx", "codex"])
        #expect(arguments == ["fix", "the", "--cwd", "bug"])
    }
}
