@testable import SwiftACP
import Foundation
import Testing

/// What Node's `spawn` refuses before starting a terminal's command, in its words
/// (#101 review): a NUL anywhere C would cut the string short, and an empty command.
/// Every expected string is what Node 25 printed for the same value.
struct NodeSpawnArgumentsTests {
    private static func refusal(
        command: String = "/bin/echo", args: [String] = [], cwd: String = "/tmp", env: [EnvVariable]? = nil
    ) -> String? {
        do {
            try NodeSpawnArguments.validate(command: command, args: args, cwd: cwd, env: env)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func eachPlaceNodeLooksIsCheckedInItsWords() {
        #expect(Self.refusal(command: "/bin/echo\0-not-echo")
            == "The argument 'file' must be a string without null bytes. Received '/bin/echo\\x00-not-echo'")
        #expect(Self.refusal(command: "") == "The argument 'file' cannot be empty. Received ''")
        #expect(Self.refusal(args: ["ok", "a\0b"])
            == "The argument 'args[1]' must be a string without null bytes. Received 'a\\x00b'")
        #expect(Self.refusal(cwd: "/tmp\0/x") == "The property 'options.cwd' must be a string, Uint8Array, "
            + "or URL without null bytes. Received '/tmp\\x00/x'")
        #expect(Self.refusal(env: [EnvVariable(name: "A", value: "v\0w")])
            == "The property 'options.env['A']' must be a string without null bytes. Received 'v\\x00w'")
        // The name is checked before the value, and shown as it is.
        #expect(Self.refusal(env: [EnvVariable(name: "A\0B", value: "v\0")])
            == "The property 'options.env['A\0B']' must be a string without null bytes. Received 'A\\x00B'")
        #expect(Self.refusal(args: ["fine"], env: [EnvVariable(name: "A", value: "fine")]) == nil)
    }

    /// Node checks the command, then the arguments, then the directory, then variables.
    @Test func theFirstRefusalInNodesOrderWins() {
        #expect(Self.refusal(command: "x\0", args: ["\0"], cwd: "\0")?.hasPrefix("The argument 'file'") == true)
        #expect(Self.refusal(args: ["\0"], cwd: "\0")?.hasPrefix("The argument 'args[0]'") == true)
        #expect(Self.refusal(cwd: "\0", env: [EnvVariable(name: "A", value: "\0")])?
            .hasPrefix("The property 'options.cwd'") == true)
    }

    /// `util.inspect`'s quoting: single quotes unless the text holds one, then double,
    /// then backticks; controls — C0, DEL, C1 — as upper-case `\xHH`, but for the short
    /// escapes.
    @Test(arguments: [
        ("a\0b", "'a\\x00b'"),
        ("it's\0", "\"it's\\x00\""),
        ("say \"hi\"\0", "'say \"hi\"\\x00'"),
        ("both ' and \" \0", "`both ' and \" \\x00`"),
        ("all ' \" ` \0", "'all \\' \" ` \\x00'"),
        ("tab\t\0", "'tab\\t\\x00'"),
        ("esc\u{1B}\0", "'esc\\x1B\\x00'"),
        ("del\u{7F}\0", "'del\\x7F\\x00'"),
        ("back\\slash\0", "'back\\\\slash\\x00'"),
        ("é\0", "'é\\x00'"),
        ("\u{0B}\u{0C}\u{08}\r\0", "'\\x0B\\f\\b\\r\\x00'"),
        ("a\u{85}\u{9F}\u{A0}b", "'a\\x85\\x9F\u{A0}b'")
    ])
    func stringsAreQuotedAsNodeQuotesThem(value: String, expected: String) {
        #expect(NodeSpawnArguments.inspected(value) == expected)
    }

    /// Over 76 characters, a string is split after each newline; the whole is cut at 128.
    @Test func longStringsAreSplitAndCutAsNodeDoes() {
        #expect(NodeSpawnArguments.inspected(String(repeating: "x", count: 200) + "\0")
            == "'" + String(repeating: "x", count: 127) + "...")
        #expect(NodeSpawnArguments.inspected("line1\n" + String(repeating: "y", count: 130) + "\0")
            == "'line1\\n' +\n  '" + String(repeating: "y", count: 113) + "...")
        #expect(NodeSpawnArguments.inspected(String(repeating: "x", count: 75) + "\ny")
            == "'" + String(repeating: "x", count: 75) + "\\n' +\n  'y'")
        // At 76 characters it stays whole, and a trailing newline adds no empty piece.
        #expect(NodeSpawnArguments.inspected(String(repeating: "x", count: 74) + "\ny")
            == "'" + String(repeating: "x", count: 74) + "\\ny'")
        #expect(NodeSpawnArguments.inspected(String(repeating: "x", count: 125) + "\n")
            == "'" + String(repeating: "x", count: 125) + "\\n...")
        // A "\r\n" splits after its "\n", as Node splits it.
        #expect(NodeSpawnArguments.inspected(String(repeating: "x", count: 80) + "\r\nz")
            == "'" + String(repeating: "x", count: 80) + "\\r\\n' +\n  'z'")
    }
}
