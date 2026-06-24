@testable import acpx
import SwiftACP
import Testing

/// Locks `acpx --help` to byte-parity with acpx 0.11.0 (commander.js 15 layout):
/// the term-column padding, the 80-column `boxWrap`, the `minWidthToWrap`
/// short-circuit, and the command-tree resolver.
struct HelpTests {
    // MARK: Full-screen snapshots

    /// The per-agent screen exercises wrapping in *both* the Options block
    /// (`--no-wait`, `-f, --file`) and the Commands block (`status`, `sessions`),
    /// including the continuation-line indent under the description column.
    @Test func agentScreenMatchesCommanderLayout() {
        let expected = """
            Usage: acpx codex [options] [command] [prompt...]

            Use codex agent

            Arguments:
              prompt                        Prompt text

            Options:
              -s, --session <name>          Use named session instead of cwd default
              --no-wait                     Queue prompt and return immediately when another
                                            prompt is already running
              -f, --file <path>             Read prompt text from file path (use - for
                                            stdin)
              -h, --help                    display help for command

            Commands:
              prompt [options] [prompt...]  Prompt using persistent session
              exec [options] [prompt...]    One-shot prompt without saved session
              cancel [options]              Cooperatively cancel current in-flight prompt
              set-mode [options] <mode>     Set session mode
              set [options] <key> <value>   Set session config option
              status [options]              Show local status of current session agent
                                            process
              sessions [options]            List, ensure, create, or close sessions for this
                                            agent

            """
        #expect(HelpRenderer.render(HelpCatalog.agent("codex")) == expected)
    }

    /// A wide-term screen (the root) stays unwrapped because the remaining width
    /// drops below `minWidthToWrap`, so long descriptions overflow 80 columns.
    @Test func rootScreenDoesNotWrapWideTerms() {
        let rendered = HelpRenderer.render(HelpCatalog.root(cwd: "/tmp"))
        #expect(rendered.contains("Usage: acpx [options] [command] [prompt...]"))
        #expect(rendered.contains("Headless CLI client for the Agent Client Protocol"))
        // 23 globals + auto -h, with the long permission-policy line on one line.
        #expect(
            rendered.contains(
                "  --permission-policy <json-or-file>      Permission policy JSON or path "
                    + "(autoApprove, autoDeny, escalate, defaultAction)"))
        #expect(rendered.contains("--cwd <dir>                             Working directory (default: \"/tmp\")"))
        #expect(rendered.hasSuffix("acpx --agent ./my-custom-server \"do something\"\n"))
    }

    /// The sub-subcommand reproduces acpx's doubled `(default: 20)` verbatim.
    @Test func sessionsHistoryKeepsDoubledDefault() throws {
        let rendered = HelpRenderer.render(try #require(HelpCatalog.sessionsChild("history", prefix: "sessions")))
        #expect(rendered.hasPrefix("Usage: acpx sessions history [options] [name]\n"))
        #expect(rendered.contains("--limit <count>  Maximum number of entries to show (default: 20) (default: 20)"))
    }

    // MARK: Resolver

    @Test func resolverMapsPathsToScreens() {
        let agents = Set(AgentRegistry.builtIn.keys)
        func usage(_ path: [String]) -> String {
            HelpRouter.screen(path: path, knownAgents: agents, cwd: "/tmp").usagePath
        }
        #expect(usage([]) == "") // root
        #expect(usage(["exec"]) == "exec")
        #expect(usage(["sessions", "list"]) == "sessions list")
        #expect(usage(["codex"]) == "codex")
        #expect(usage(["codex", "exec"]) == "codex exec")
        #expect(usage(["codex", "sessions", "new"]) == "codex sessions new")
        #expect(usage(["config", "show"]) == "config show")
        #expect(usage(["flow", "run"]) == "flow run")
        // Unknown leaf falls back to the nearest known node.
        #expect(usage(["bogus"]) == "")
        #expect(usage(["sessions", "bogus"]) == "sessions")
    }

    /// Top-level subcommand descriptions name the default agent; per-agent ones
    /// describe the underlying action.
    @Test func topLevelAndAgentDescriptionsDiffer() {
        let agents = Set(AgentRegistry.builtIn.keys)
        let topExec = HelpRouter.screen(path: ["exec"], knownAgents: agents, cwd: "/tmp")
        let agentExec = HelpRouter.screen(path: ["codex", "exec"], knownAgents: agents, cwd: "/tmp")
        #expect(topExec.description == "One-shot prompt using codex by default")
        #expect(agentExec.description == "One-shot prompt without saved session")
    }

    @Test func rootListsAllRegistryAgentsInOrder() {
        let root = HelpCatalog.root(cwd: "/tmp")
        let agentTerms = AgentRegistry.orderedNames.map { "\($0) [options] [prompt...]" }
        // The first 18 Commands rows are the agents, in registry order.
        let leadingTerms = root.subcommands.prefix(agentTerms.count).map(\.term)
        #expect(Array(leadingTerms) == agentTerms)
        #expect(AgentRegistry.orderedNames.first == "pi")
        #expect(AgentRegistry.orderedNames.count == 18)
    }

    // MARK: boxWrap algorithm

    @Test func boxWrapGreedilyBreaksAtWordBoundaries() {
        // width 48 fills exactly to "another" (48 chars) before breaking.
        let wrapped = HelpRenderer.boxWrap(
            "Queue prompt and return immediately when another prompt is already running", 48)
        #expect(wrapped == "Queue prompt and return immediately when another\nprompt is already running")
    }

    @Test func boxWrapSkippedBelowMinWidth() {
        // Below minWidthToWrap (40) commander returns the string untouched.
        let text = "When prompting is unavailable: deny or fail"
        #expect(HelpRenderer.boxWrap(text, 38) == text)
    }
}
