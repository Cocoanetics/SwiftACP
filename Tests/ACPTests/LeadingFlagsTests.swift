@testable import ACPXCore
@testable import acpx
import Testing

/// acpx reads a few things off the raw arguments before it parses them (#69): the
/// output format a top-level failure is reported in, and the directory and MCP file
/// its config comes from. Each expectation below is what acpx 0.19.1's scans
/// (`detectRequestedOutputFormat`, `detectInitialCwd`, `detectMcpConfigPath`) give.
@Suite struct LeadingFlagsTests {
    private static func format(_ arguments: [String]) -> String {
        LeadingFlags.requestedFormat(arguments) { "fallback" }
    }

    /// Only the leading flags count: the scan stops at the first word that is not a
    /// flag and steps over a global flag's value.
    @Test func theFormatComesFromTheLeadingFlags() {
        #expect(Self.format(["--cwd", "/tmp", "--format", "quiet", "x"]) == "quiet")
        #expect(Self.format(["--format=json", "x"]) == "json")
        #expect(Self.format(["--json-strict", "x"]) == "json")
        #expect(Self.format(["--format", "json", "--json-strict=no"]) == "json")
        #expect(Self.format(["--format", "xml", "--format", "json"]) == "json")
        #expect(Self.format(["--format", "json", "--format", "xml"]) == "json")
        #expect(Self.format(["codex", "--format", "json"]) == "fallback")
        #expect(Self.format(["--model", "--format", "json"]) == "fallback")
        #expect(Self.format(["--unknown", "--format", "quiet"]) == "quiet")
        #expect(Self.format(["--", "--format", "json"]) == "fallback")
    }

    /// `--format=<value>` is trimmed as JavaScript trims; `--format <value>` is taken
    /// as given.
    @Test func onlyAnInlineFormatIsTrimmed() {
        #expect(Self.format(["--format= json\u{3000}", "x"]) == "json")
        #expect(Self.format(["--format", " json", "x"]) == "fallback")
        #expect(Self.format(["--format=json\u{85}", "x"]) == "fallback")
    }

    /// `compare` has its own `--format` and `--json`: the alias wins, a global format
    /// beats a local one, and a local one beats the fallback.
    @Test func compareWeighsItsOwnFormat() {
        #expect(Self.format(["compare", "--json", "a", "b", "hi"]) == "json")
        #expect(Self.format(["compare", "a", "--format", "quiet", "hi"]) == "quiet")
        #expect(Self.format(["--format", "text", "compare", "--format", "quiet", "a", "hi"]) == "text")
        #expect(Self.format(["--format", "text", "compare", "--json", "a", "hi"]) == "json")
        #expect(Self.format(["compare", "--format", "xml", "a", "hi"]) == "fallback")
        #expect(Self.format(["compare", "a", "--", "--json"]) == "fallback")
        #expect(Self.format(["--timeout", "5", "compare", "--json"]) == "json")
        #expect(Self.format(["--file", "p.txt", "compare", "--json"]) == "json")
        // A flag the command scan does not know hides the command.
        #expect(Self.format(["--fs", "compare", "--json"]) == "fallback")
        // `--timeout` takes `--json` as its value.
        #expect(Self.format(["compare", "--timeout", "--json", "a", "hi"]) == "fallback")
    }

    @Test func theConfigDirectoryIsTheLeadingOrComparesCwd() {
        #expect(LeadingFlags.initialCwd(["--cwd", "/a", "exec", "--cwd", "/b"], base: "/base") == "/a")
        #expect(LeadingFlags.initialCwd(["exec", "--cwd", "/b"], base: "/base") == "/base")
        #expect(LeadingFlags.initialCwd(["--cwd", "rel/../dir", "x"], base: "/base") == "/base/dir")
        #expect(LeadingFlags.initialCwd(["--cwd=", "x"], base: "/base") == "/base")
        #expect(LeadingFlags.initialCwd(["--cwd=/a", "compare", "--cwd", "/c", "x", "y"], base: "/base") == "/c")
        #expect(LeadingFlags.initialCwd(["--cwd=/a", "compare", "x", "y"], base: "/base") == "/a")
    }

    @Test func theMcpFileIsTheLastLeadingOne() {
        #expect(LeadingFlags.mcpConfigPath(["--mcp-config", "a.json", "--mcp-config=b.json", "x"]) == "b.json")
        #expect(LeadingFlags.mcpConfigPath(["--mcp-config=", "x"]) == nil)
        #expect(LeadingFlags.mcpConfigPath(["x", "--mcp-config", "a.json"]) == nil)
    }

    /// The flags whose value the scans step over are acpx's
    /// `TOP_LEVEL_VERSION_VALUE_FLAG_VALUES`.
    @Test func theValueFlagsAreAcpxs() {
        #expect(LeadingFlags.valueFlags == [
            "--agent", "--cwd", "--auth-policy", "--non-interactive-permissions", "--permission-policy",
            "--policy", "--format", "--model", "--allowed-tools", "--max-turns", "--system-prompt",
            "--append-system-prompt", "--prompt-retries", "--timeout", "--ttl", "--mcp-config"
        ])
    }

    /// `String.prototype.trim` takes JavaScript's whitespace and line terminators and
    /// the BOM, but not U+0085, which Foundation counts as a newline.
    @Test func javaScriptTrimKeepsNextLine() {
        #expect(" \u{FEFF}\u{2028}x\u{3000}\u{200A}\n".javaScriptTrimmed == "x")
        #expect("\u{85}x\u{85}".javaScriptTrimmed == "\u{85}x\u{85}")
    }
}
