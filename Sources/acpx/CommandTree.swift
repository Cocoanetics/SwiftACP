import ACPXCore
import SwiftACP

/// One command in acpx's commander tree (see ``CommandTree``): its options, its
/// arguments and its subcommands, with the parse settings commander gives it.
struct CommandSpec {
    /// A registered argument: `<mode>`, `[name]`, `[prompt...]`.
    struct Argument {
        let name: String
        let required: Bool
        var variadic = false
        /// The argument's `parseArg`, run on its value once the command is chosen. It
        /// throws the bare reason; the parse frames it with the argument's name.
        var validate: (@Sendable (String) throws -> Void)?
    }

    let name: String
    var options: [OptionSpec] = []
    var arguments: [Argument] = []
    var subcommands: [CommandSpec] = []
    /// `passThroughOptions()`: the first operand ends option parsing, so everything after
    /// it is an operand, flags included — the agent commands' prompts.
    var passThrough = false
    /// Whether the command runs something itself. `flow` only groups `run`.
    var hasAction = true

    func subcommand(_ name: String) -> CommandSpec? {
        subcommands.first { $0.name == name }
    }

    func option(matching arg: String) -> OptionSpec? {
        options.first { $0.matches(arg) }
    }

    /// commander's `helpCommand(true)`: a `help [command]` command whatever else the
    /// command has, as acpx 0.19.3 gives its root (openclaw/acpx#763). Unset, commander's
    /// own rule decides (``hasHelpCommand``).
    var helpCommand: Bool?

    /// Whether the command has commander's `help [command]` command: the root since
    /// acpx 0.19.3 (``helpCommand``), and otherwise, commander's implicit one, only a
    /// command that has subcommands and no action — in acpx, `flow`.
    var hasHelpCommand: Bool { helpCommand ?? (!subcommands.isEmpty && !hasAction) }
}

/// acpx 0.19.1's commander tree as `configurePublicCli` leaves it: the root, with the
/// global options and the bare-prompt action; a command per agent; and the verbs.
/// Every command has positional options, inherited from the root's
/// `enablePositionalOptions()`, and the agent commands pass their prompts through.
/// `CommandTreeTests` compares it with a dump of npm acpx's own tree.
enum CommandTree {
    static func acpx(agents: [String]) -> CommandSpec {
        var root = CommandSpec(
            name: "acpx", options: [versionOption] + Flags.globalSpecs, arguments: [promptArgument],
            subcommands: agents.map(agent) + verbs + [config, compare, flow])
        // `configurePublicCli`: `acpx help [command]` shows usage (acpx 0.19.3, #778).
        root.helpCommand = true
        return root
    }

    /// The agent commands acpx registers: the built-ins and the config's
    /// (`listBuiltInAgents`), then — `configurePublicCli` — the command line's first word
    /// when it is neither those nor a verb and no `--agent` came before it. So an unknown
    /// word is an agent: `acpx foo hi` prompts agent `foo`.
    static func agentNames(config: ResolvedAcpxConfig, arguments: [String]) -> [String] {
        var names = AgentRegistry.orderedNames
        for name in config.agentOrder where !names.contains(name) {
            names.append(name)
        }
        let scan = LeadingFlags.command(arguments)
        if !scan.hasAgentOverride, let token = scan.token, !topLevelVerbs.contains(token),
            !names.contains(token) {
            names.append(token)
        }
        return names
    }

    /// `TOP_LEVEL_VERBS`: never taken for an agent name.
    static let topLevelVerbs: Set<String> = [
        "prompt", "exec", "cancel", "compare", "flow", "set-mode", "set", "sessions", "status", "config", "help"
    ]

    /// `-V, --version`: commander prints the version as soon as it parses it.
    static let versionOption = OptionSpec("version", short: "V")

    static func agent(_ name: String) -> CommandSpec {
        CommandSpec(
            name: name, options: [sessionOption, noWaitOption, fileOption], arguments: [promptArgument],
            subcommands: verbs, passThrough: true)
    }

    // MARK: Shared pieces

    private static let promptArgument = CommandSpec.Argument(name: "prompt", required: false, variadic: true)
    private static let nameArgument = CommandSpec.Argument(name: "name", required: false, validate: sessionName)
    private static let sessionOption = OptionSpec(
        "session", short: "s", takesValue: true, value: "name", validate: sessionName)
    private static let noWaitOption = OptionSpec("no-wait")
    private static let fileOption = OptionSpec("file", short: "f", takesValue: true, value: "path")
    private static let formatOption = OptionSpec(
        "format", takesValue: true, value: "fmt", validate: { _ = try parseOutputFormat($0) })

    private static let sessionName: @Sendable (String) throws -> Void = { _ = try parseSessionName($0) }

    private static func nonEmpty(_ label: String) -> @Sendable (String) throws -> Void {
        { _ = try parseNonEmptyValue(label, $0) }
    }

    // MARK: The verbs, under the root and under every agent

    private static let verbs: [CommandSpec] = [
        CommandSpec(name: "prompt", options: [sessionOption, noWaitOption, fileOption], arguments: [promptArgument]),
        CommandSpec(
            name: "exec",
            options: [
                fileOption,
                OptionSpec(
                    "config-option", takesValue: true, repeats: true, value: "key=value",
                    validate: { _ = try parseSessionConfigOptionAssignment($0) })
            ],
            arguments: [promptArgument]),
        CommandSpec(name: "cancel", options: [sessionOption]),
        CommandSpec(
            name: "set-mode", options: [sessionOption],
            arguments: [.init(name: "mode", required: true, validate: nonEmpty("Mode"))]),
        CommandSpec(
            name: "set", options: [sessionOption],
            arguments: [
                .init(name: "key", required: true, validate: nonEmpty("Config option key")),
                .init(name: "value", required: true, validate: nonEmpty("Config option value"))
            ]),
        CommandSpec(name: "status", options: [sessionOption]),
        sessions
    ]

    private static let sessionsListOptions = [
        OptionSpec("local"),
        OptionSpec("cursor", takesValue: true, value: "cursor", validate: nonEmpty("Cursor")),
        OptionSpec("filter-cwd", takesValue: true, value: "dir", validate: nonEmpty("Filter cwd"))
    ]

    private static let sessionNameOption = OptionSpec(
        "name", short: "s", takesValue: true, value: "name", validate: sessionName)

    private static let sessionCreateOptions = [
        sessionNameOption,
        OptionSpec("resume-session", takesValue: true, value: "id", validate: nonEmpty("Resume session id"))
    ]

    private static let sessions = CommandSpec(
        name: "sessions", options: sessionsListOptions,
        subcommands: [
            CommandSpec(name: "list", options: sessionsListOptions),
            CommandSpec(name: "new", options: sessionCreateOptions),
            CommandSpec(name: "ensure", options: sessionCreateOptions),
            CommandSpec(name: "close", arguments: [nameArgument]),
            CommandSpec(name: "show", arguments: [nameArgument]),
            CommandSpec(
                name: "history",
                options: [
                    OptionSpec("limit", takesValue: true, value: "count", validate: { _ = try parseHistoryLimit($0) })
                ],
                arguments: [nameArgument]),
            CommandSpec(
                name: "read",
                options: [
                    OptionSpec("tail", takesValue: true, value: "count", validate: { _ = try parseHistoryLimit($0) })
                ],
                arguments: [nameArgument]),
            CommandSpec(
                name: "watch",
                options: [
                    sessionNameOption,
                    OptionSpec("cursor", takesValue: true, value: "cursor", validate: nonEmpty("Cursor"))
                ]),
            CommandSpec(
                name: "export",
                options: [
                    OptionSpec(
                        "output", takesValue: true, value: "path", mandatory: true, validate: nonEmpty("Output path")),
                    // Kept apart from the root's `--cwd` (acpx's attribute is `sourceCwd`).
                    OptionSpec(
                        "cwd", takesValue: true, value: "cwd", key: "source-cwd", validate: nonEmpty("Session cwd"))
                ],
                arguments: [nameArgument]),
            CommandSpec(
                name: "import",
                options: [
                    OptionSpec("name", takesValue: true, value: "name", validate: sessionName),
                    OptionSpec(
                        "cwd", takesValue: true, value: "cwd", key: "destination-cwd",
                        validate: nonEmpty("Imported session cwd"))
                ],
                arguments: [.init(name: "archive-path", required: true, validate: nonEmpty("Archive path"))]),
            CommandSpec(
                name: "prune",
                options: [
                    OptionSpec("dry-run"),
                    OptionSpec("before", takesValue: true, value: "date", validate: { _ = try parseBeforeDate($0) }),
                    OptionSpec(
                        "older-than", takesValue: true, value: "days", validate: { _ = try parseDaysOlderThan($0) }),
                    OptionSpec("include-history")
                ])
        ])

    // MARK: Root-only verbs

    private static let config = CommandSpec(
        name: "config",
        subcommands: [
            CommandSpec(name: "show", options: [formatOption]),
            CommandSpec(name: "init", options: [formatOption])
        ])

    private static let compare = CommandSpec(
        name: "compare",
        options: [
            OptionSpec("cwd", takesValue: true, value: "dir"),
            OptionSpec("approve-all"),
            OptionSpec("approve-reads"),
            OptionSpec("deny-all"),
            OptionSpec("timeout", takesValue: true, value: "seconds", validate: { _ = try parseTimeoutSeconds($0) }),
            formatOption,
            OptionSpec("json"),
            OptionSpec("file", short: "f", takesValue: true, value: "path", validate: nonEmpty("Prompt file")),
            OptionSpec("prompt-file", takesValue: true, value: "path", validate: nonEmpty("Prompt file"))
        ],
        arguments: [.init(name: "args", required: true, variadic: true)])

    private static let flow = CommandSpec(
        name: "flow",
        subcommands: [
            CommandSpec(
                name: "run",
                options: [
                    OptionSpec("input-json", takesValue: true, value: "json"),
                    OptionSpec("input-file", takesValue: true, value: "path"),
                    OptionSpec("default-agent", takesValue: true, value: "name", validate: nonEmpty("Default agent"))
                ],
                arguments: [.init(name: "file", required: true)])
        ],
        hasAction: false)
}
