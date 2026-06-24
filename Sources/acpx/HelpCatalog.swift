import SwiftACP

// MARK: - Command-tree data

/// The static command tree behind `acpx --help`, transcribed from acpx 0.11.0.
/// Most option/argument rows are shared between the top-level commands and their
/// per-agent equivalents; only the usage path prefix and a handful of
/// descriptions differ.
enum HelpCatalog {
    // Shared option rows.
    private static let sessionOpt = HelpOption("-s, --session <name>", "Use named session instead of cwd default")
    private static let noWaitOpt = HelpOption(
        "--no-wait", "Queue prompt and return immediately when another prompt is already running")
    private static let fileOpt = HelpOption("-f, --file <path>", "Read prompt text from file path (use - for stdin)")

    // Shared argument rows.
    private static let promptArg = HelpArgument("prompt", "[prompt...]", "Prompt text")
    private static let nameArg = HelpArgument("name", "[name]", "Session name")

    /// The agent subcommands carried both at top level and under each agent.
    static let agentSubcommandNames: Set<String> = [
        "prompt", "exec", "cancel", "set-mode", "set", "status", "sessions"
    ]

    // MARK: Root

    static func root(cwd: String) -> HelpScreen {
        var subs: [HelpSubcommand] = AgentRegistry.orderedNames.map {
            HelpSubcommand("\($0) [options] [prompt...]", "Use \($0) agent")
        }
        subs += [
            HelpSubcommand("prompt [options] [prompt...]", topDescription("prompt")),
            HelpSubcommand("exec [options] [prompt...]", topDescription("exec")),
            HelpSubcommand("cancel [options]", topDescription("cancel")),
            HelpSubcommand("set-mode [options] <mode>", topDescription("set-mode")),
            HelpSubcommand("set [options] <key> <value>", topDescription("set")),
            HelpSubcommand("status [options]", topDescription("status")),
            HelpSubcommand("sessions [options]", topDescription("sessions")),
            HelpSubcommand("config", topDescription("config")),
            HelpSubcommand("compare [options] <args...>", topDescription("compare")),
            HelpSubcommand("flow", topDescription("flow"))
        ]
        return HelpScreen(
            usagePath: "",
            description: "Headless CLI client for the Agent Client Protocol",
            arguments: [promptArg],
            options: globalOptions(cwd: cwd),
            subcommands: subs,
            after: examples)
    }

    /// The 24 global options, listed only on the root command (cwd is dynamic).
    private static func globalOptions(cwd: String) -> [HelpOption] {
        [
            HelpOption("-V, --version", "output the version number"),
            HelpOption("--agent <command>", "Raw ACP agent command (escape hatch)"),
            HelpOption("--cwd <dir>", "Working directory (default: \"\(cwd)\")"),
            HelpOption("--auth-policy <policy>", "Authentication policy: skip or fail when auth is required"),
            HelpOption("--approve-all", "Auto-approve all permission requests"),
            HelpOption("--approve-reads", "Auto-approve read/search requests and prompt for writes"),
            HelpOption("--deny-all", "Deny all permission requests"),
            HelpOption("--non-interactive-permissions <policy>", "When prompting is unavailable: deny or fail"),
            HelpOption(
                "--permission-policy <json-or-file>",
                "Permission policy JSON or path (autoApprove, autoDeny, escalate, defaultAction)"),
            HelpOption("--policy <json-or-file>", "Alias for --permission-policy"),
            HelpOption("--format <fmt>", "Output format: text, json, quiet"),
            HelpOption("--suppress-reads", "Suppress raw read-file contents in output"),
            HelpOption("--model <id>", "Agent model id"),
            HelpOption(
                "--allowed-tools <list>", "Allowed tool names as a comma-separated list (use \"\" for no tools)"),
            HelpOption("--max-turns <count>", "Maximum turns for the session"),
            HelpOption(
                "--system-prompt <text>",
                "Replace the agent system prompt (claude-agent-acp via ACP _meta.systemPrompt)"),
            HelpOption(
                "--append-system-prompt <text>",
                "Append text to the agent system prompt (claude-agent-acp via ACP _meta.systemPrompt.append)"),
            HelpOption("--prompt-retries <count>", "Retry failed prompt turns on transient errors (default: 0)"),
            HelpOption(
                "--json-strict", "Strict JSON mode: requires --format json and suppresses non-JSON stderr output"),
            HelpOption("--no-terminal", "Do not advertise ACP terminal capability"),
            HelpOption("--timeout <seconds>", "Maximum time to wait for agent response"),
            HelpOption(
                "--ttl <seconds>", "Queue owner idle TTL before shutdown (0 = keep alive forever) (default: 300)"),
            HelpOption("--verbose", "Enable verbose debug logs")
        ]
    }

    private static let examples = """
        Examples:
          acpx pi "review recent changes"
          acpx openclaw exec "summarize active session state"
          acpx codex sessions new
          acpx codex "fix the tests"
          acpx codex prompt "fix the tests"
          acpx codex --no-wait "queue follow-up task"
          acpx codex exec "what does this repo do"
          acpx codex cancel
          acpx codex set-mode plan
          acpx codex set model 'gpt-5.2[high]'
          acpx codex -s backend "fix the API"
          acpx codex sessions
          acpx codex sessions new --name backend
          acpx codex sessions ensure --name backend
          acpx codex sessions close backend
          acpx codex status
          acpx config show
          acpx config init
          acpx --ttl 30 codex "investigate flaky tests"
          acpx claude "refactor auth"
          acpx --agent ./my-custom-server "do something"
        """

    // MARK: Agent node

    static func agent(_ name: String) -> HelpScreen {
        HelpScreen(
            usagePath: name,
            description: "Use \(name) agent",
            arguments: [promptArg],
            options: [sessionOpt, noWaitOpt, fileOpt],
            subcommands: [
                HelpSubcommand("prompt [options] [prompt...]", agentDescription("prompt")),
                HelpSubcommand("exec [options] [prompt...]", agentDescription("exec")),
                HelpSubcommand("cancel [options]", agentDescription("cancel")),
                HelpSubcommand("set-mode [options] <mode>", agentDescription("set-mode")),
                HelpSubcommand("set [options] <key> <value>", agentDescription("set")),
                HelpSubcommand("status [options]", agentDescription("status")),
                HelpSubcommand("sessions [options]", agentDescription("sessions"))
            ])
    }

    // MARK: Subcommands (shared between top level and per-agent)

    /// The args/options for an agent subcommand; usage path and description are
    /// supplied by the caller (they differ between top-level and per-agent).
    private static func subcommandBody(_ name: String) -> HelpScreen? {
        switch name {
        case "prompt":
            return HelpScreen(
                usagePath: "", description: "", arguments: [promptArg],
                options: [sessionOpt, noWaitOpt, fileOpt])
        case "exec":
            return HelpScreen(usagePath: "", description: "", arguments: [promptArg], options: [fileOpt])
        case "cancel":
            return HelpScreen(usagePath: "", description: "", options: [sessionOpt])
        case "set-mode":
            return HelpScreen(
                usagePath: "", description: "", arguments: [HelpArgument("mode", "<mode>", "Mode id")],
                options: [sessionOpt])
        case "set":
            return HelpScreen(
                usagePath: "", description: "",
                arguments: [
                    HelpArgument("key", "<key>", "Config option id"),
                    HelpArgument("value", "<value>", "Config option value")
                ], options: [sessionOpt])
        case "status":
            return HelpScreen(usagePath: "", description: "", options: [sessionOpt])
        case "sessions":
            return HelpScreen(
                usagePath: "", description: "",
                options: [
                    HelpOption("--local", "List local acpx session records instead of agent protocol sessions"),
                    HelpOption("--cursor <cursor>", "Opaque ACP session/list cursor"),
                    HelpOption("--filter-cwd <dir>", "Filter agent sessions by working directory")
                ],
                subcommands: sessionsSubcommands)
        default:
            return nil
        }
    }

    /// Top-level subcommand screen, e.g. `acpx exec --help`.
    static func topSubcommand(_ name: String) -> HelpScreen? {
        if name == "config" { return config(usagePath: "config") }
        if name == "compare" { return compare(usagePath: "compare") }
        if name == "flow" { return flow(usagePath: "flow") }
        guard var screen = subcommandBody(name) else { return nil }
        screen.usagePath = name
        screen.description = topDescription(name)
        return screen
    }

    /// Per-agent subcommand screen, e.g. `acpx codex exec --help`.
    static func agentSubcommand(_ agent: String, _ name: String) -> HelpScreen? {
        guard var screen = subcommandBody(name) else { return nil }
        screen.usagePath = "\(agent) \(name)"
        screen.description = agentDescription(name)
        return screen
    }

    // MARK: sessions / config / flow children

    private static let sessionsSubcommands: [HelpSubcommand] = [
        HelpSubcommand("list [options]", "List sessions"),
        HelpSubcommand("new [options]", "Create a fresh session for current cwd"),
        HelpSubcommand("ensure [options]", "Ensure a session exists for current cwd or ancestor"),
        HelpSubcommand("close [name]", "Close session for current cwd"),
        HelpSubcommand("show [name]", "Show session metadata for current cwd"),
        HelpSubcommand("history [options] [name]", "Show recent session history entries"),
        HelpSubcommand("read [options] [name]", "Read full session history"),
        HelpSubcommand("export [options] [name]", "Export a portable session archive"),
        HelpSubcommand("import [options] <archive-path>", "Import a portable session archive"),
        HelpSubcommand("prune [options]", "Delete closed sessions and free disk space")
    ]

    /// A `sessions <child> --help` screen under the given usage prefix
    /// (`"sessions"` or `"<agent> sessions"`).
    static func sessionsChild(_ child: String, prefix: String) -> HelpScreen? {
        let path = "\(prefix) \(child)"
        switch child {
        case "list":
            return HelpScreen(
                usagePath: path, description: "List sessions",
                options: [
                    HelpOption("--local", "List local acpx session records instead of agent protocol sessions"),
                    HelpOption("--cursor <cursor>", "Opaque ACP session/list cursor"),
                    HelpOption("--filter-cwd <dir>", "Filter agent sessions by working directory")
                ])
        case "new":
            return HelpScreen(
                usagePath: path, description: "Create a fresh session for current cwd",
                options: [
                    HelpOption("-s, --name <name>", "Session name"),
                    HelpOption("--resume-session <id>", "Resume existing ACP session id")
                ])
        case "ensure":
            return HelpScreen(
                usagePath: path, description: "Ensure a session exists for current cwd or ancestor",
                options: [
                    HelpOption("-s, --name <name>", "Session name"),
                    HelpOption("--resume-session <id>", "Resume existing ACP session id")
                ])
        case "close":
            return HelpScreen(
                usagePath: path, description: "Close session for current cwd", arguments: [nameArg])
        case "show":
            return HelpScreen(
                usagePath: path, description: "Show session metadata for current cwd", arguments: [nameArg])
        case "history":
            return HelpScreen(
                usagePath: path, description: "Show recent session history entries", arguments: [nameArg],
                options: [
                    HelpOption("--limit <count>", "Maximum number of entries to show (default: 20) (default: 20)")
                ])
        case "read":
            return HelpScreen(
                usagePath: path, description: "Read full session history", arguments: [nameArg],
                options: [HelpOption("--tail <count>", "Show only the last N entries instead of all history")])
        case "export":
            return HelpScreen(
                usagePath: path, description: "Export a portable session archive", arguments: [nameArg],
                options: [
                    HelpOption("--output <path>", "Output archive path"),
                    HelpOption("--cwd <cwd>", "Session cwd to export")
                ])
        case "import":
            return HelpScreen(
                usagePath: path, description: "Import a portable session archive",
                arguments: [HelpArgument("archive-path", "<archive-path>", "Archive path")],
                options: [
                    HelpOption("--name <name>", "Imported session name"),
                    HelpOption("--cwd <cwd>", "Imported session cwd")
                ])
        case "prune":
            return HelpScreen(
                usagePath: path, description: "Delete closed sessions and free disk space",
                options: [
                    HelpOption("--dry-run", "Preview what would be pruned without deleting anything"),
                    HelpOption("--before <date>", "Prune sessions closed before this date"),
                    HelpOption("--older-than <days>", "Prune sessions closed more than N days ago"),
                    HelpOption("--include-history", "Also delete event stream files (.stream.ndjson)")
                ])
        default:
            return nil
        }
    }

    private static func config(usagePath: String) -> HelpScreen {
        HelpScreen(
            usagePath: usagePath, description: "Inspect and initialize acpx configuration",
            subcommands: [
                HelpSubcommand("show [options]", "Show resolved config"),
                HelpSubcommand("init [options]", "Create global config template")
            ])
    }

    static func configChild(_ child: String) -> HelpScreen? {
        switch child {
        case "show":
            return HelpScreen(
                usagePath: "config show", description: "Show resolved config",
                options: [HelpOption("--format <fmt>", "Output format: text, json, quiet")])
        case "init":
            return HelpScreen(
                usagePath: "config init", description: "Create global config template",
                options: [HelpOption("--format <fmt>", "Output format: text, json, quiet")])
        default:
            return nil
        }
    }

    private static func flow(usagePath: String) -> HelpScreen {
        HelpScreen(
            usagePath: usagePath, description: "Run multi-step ACP workflows from flow files",
            subcommands: [
                HelpSubcommand("run [options] <file>", "Run a flow file"),
                HelpSubcommand("help [command]", "display help for command")
            ])
    }

    static func flowChild(_ child: String) -> HelpScreen? {
        guard child == "run" else { return nil }
        return HelpScreen(
            usagePath: "flow run", description: "Run a flow file",
            arguments: [HelpArgument("file", "<file>", "Flow module path")],
            options: [
                HelpOption("--input-json <json>", "Flow input as JSON"),
                HelpOption("--input-file <path>", "Read flow input JSON from file"),
                HelpOption("--default-agent <name>", "Default agent profile for ACP nodes without profile")
            ])
    }

    private static func compare(usagePath: String) -> HelpScreen {
        HelpScreen(
            usagePath: usagePath, description: "Run one prompt across multiple agents and summarize the results",
            arguments: [HelpArgument("args", "<args...>", "Agents followed by prompt text, or agents with --file")],
            options: [
                HelpOption("--cwd <dir>", "Target workspace"),
                HelpOption("--approve-all", "Auto-approve all permission requests"),
                HelpOption("--approve-reads", "Auto-approve read/search requests and prompt for writes"),
                HelpOption("--deny-all", "Deny all permission requests"),
                HelpOption("--timeout <seconds>", "Per-agent timeout in seconds"),
                HelpOption("--format <fmt>", "Output format: text, json, quiet"),
                HelpOption("--json", "Alias for --format json"),
                HelpOption("-f, --file <path>", "Read prompt text from file path (use - for stdin)"),
                HelpOption("--prompt-file <path>", "Alias for --file")
            ])
    }

    // MARK: Descriptions

    /// Top-level subcommand descriptions reference the default agent by name.
    private static func topDescription(_ name: String) -> String {
        let agent = AgentRegistry.defaultAgent
        switch name {
        case "prompt": return "Prompt using \(agent) by default"
        case "exec": return "One-shot prompt using \(agent) by default"
        case "cancel": return "Cancel active prompt for \(agent) by default"
        case "set-mode": return "Set session mode for \(agent) by default"
        case "set": return "Set session config option for \(agent) by default"
        case "status": return "Show local status for \(agent) by default"
        case "sessions": return "List, ensure, create, or close sessions for this agent"
        case "config": return "Inspect and initialize acpx configuration"
        case "compare": return "Run one prompt across multiple agents and summarize the results"
        case "flow": return "Run multi-step ACP workflows from flow files"
        default: return ""
        }
    }

    private static func agentDescription(_ name: String) -> String {
        switch name {
        case "prompt": return "Prompt using persistent session"
        case "exec": return "One-shot prompt without saved session"
        case "cancel": return "Cooperatively cancel current in-flight prompt"
        case "set-mode": return "Set session mode"
        case "set": return "Set session config option"
        case "status": return "Show local status of current session agent process"
        case "sessions": return "List, ensure, create, or close sessions for this agent"
        default: return ""
        }
    }
}

// MARK: - Resolver

/// Maps an argv positional path to the `HelpScreen` commander would show for
/// `--help` at that point in the tree, then renders it.
enum HelpRouter {
    static func render(path: [String], knownAgents: Set<String>, cwd: String) -> String {
        HelpRenderer.render(screen(path: path, knownAgents: knownAgents, cwd: cwd))
    }

    static func screen(path: [String], knownAgents: Set<String>, cwd: String) -> HelpScreen {
        var path = path

        // Optional leading agent name selects the per-agent subtree.
        if let first = path.first, knownAgents.contains(AgentRegistry.normalize(first)) {
            let agent = AgentRegistry.normalize(first)
            path.removeFirst()
            guard let command = path.first else { return HelpCatalog.agent(agent) }
            if command == "sessions", path.count >= 2,
                let child = HelpCatalog.sessionsChild(path[1], prefix: "\(agent) sessions") {
                return child
            }
            return HelpCatalog.agentSubcommand(agent, command) ?? HelpCatalog.agent(agent)
        }

        guard let command = path.first else { return HelpCatalog.root(cwd: cwd) }
        switch command {
        case "sessions":
            if path.count >= 2, let child = HelpCatalog.sessionsChild(path[1], prefix: "sessions") { return child }
        case "config":
            if path.count >= 2, let child = HelpCatalog.configChild(path[1]) { return child }
        case "flow":
            if path.count >= 2, let child = HelpCatalog.flowChild(path[1]) { return child }
        default:
            break
        }
        return HelpCatalog.topSubcommand(command) ?? HelpCatalog.root(cwd: cwd)
    }
}
