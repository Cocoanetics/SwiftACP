import ACPXCore
import Foundation
import SwiftACP

/// Context passed to each command handler: the resolved agent (if any), the
/// positional args after the command path, the raw argv (for option scanning),
/// and the loaded config.
struct CommandContext {
    var explicitAgent: String?
    var positionals: [String]
    var rawArgs: [String]
    var config: ResolvedAcpxConfig

    func scan(_ specs: [OptionSpec]) throws -> ScannedArgs {
        try ArgScanner.scan(rawArgs, options: specs + Flags.globalSpecs)
    }

    /// Global options are declared on commander's *root*, so a rejected value is
    /// reported against the root — its help, and `EXIT_CODES.USAGE` — not against
    /// whichever subcommand happened to follow them.
    func globalFlags(_ scan: ScannedArgs) throws -> GlobalFlags {
        do {
            return try Flags.resolveGlobalFlags(scan, config: config)
        } catch var error as UsageError {
            error.scope = .root
            throw error
        }
    }
}

enum Router {
    static let agentSubcommands: Set<String> = [
        "prompt", "exec", "cancel", "set-mode", "set", "status", "sessions"
    ]
    static let topSubcommands: Set<String> = agentSubcommands.union(["config", "compare", "flow"])

    /// Union of option specs used only to extract a clean positional list for routing.
    static let routingSpecs: [OptionSpec] =
        Flags.globalSpecs + [
            OptionSpec("session", short: "s", takesValue: true, value: "name"),
            OptionSpec("file", short: "f", takesValue: true, value: "path"),
            OptionSpec("config-option", takesValue: true, repeats: true, value: "key=value"),
            OptionSpec("name", takesValue: true, value: "name"),
            OptionSpec("resume-session", takesValue: true, value: "id"),
            OptionSpec("cursor", takesValue: true, value: "cursor"),
            OptionSpec("filter-cwd", takesValue: true, value: "dir"),
            OptionSpec("limit", takesValue: true, value: "count"),
            OptionSpec("tail", takesValue: true, value: "count"),
            OptionSpec("output", takesValue: true, value: "path"),
            OptionSpec("before", takesValue: true, value: "date"),
            OptionSpec("older-than", takesValue: true, value: "days"),
            OptionSpec("prompt-file", takesValue: true, value: "path"),
            OptionSpec("input-json", takesValue: true, value: "json"),
            OptionSpec("input-file", takesValue: true, value: "path"),
            OptionSpec("default-agent", takesValue: true, value: "name"),
            OptionSpec("local"),
            OptionSpec("dry-run"),
            OptionSpec("include-history"),
            OptionSpec("json"),
            OptionSpec("wait", negatable: true),
            OptionSpec("version", short: "V")
        ]

    static func dispatch(_ rawArgs: [String]) throws -> Int32 {
        // Lenient: this pass only recovers the positional command path. A bad
        // option is reported by the command's own scan, which knows which help
        // to show — the same place commander reports it.
        let routing = try ArgScanner.scan(rawArgs, options: routingSpecs, lenient: true)
        let cwd = routing.string("cwd") ?? physicalCWD()
        // `--mcp-config` is resolved here, with the config, because its servers
        // replace the config-file ones for the whole invocation (relative to `--cwd`,
        // as in npm acpx).
        let config = try ConfigLoader.load(
            cwd: ACPXPaths.resolve(cwd, base: physicalCWD()),
            mcpConfigPath: ConfigLoader.explicitMcpConfigPath(routing.string("mcp-config")))
        let knownAgents = Set(AgentRegistry.builtIn.keys)
            .union(AgentRegistry.aliases.keys)
            .union(config.agents.keys)

        // `--version` / `-V` prints the bare version string (commander style).
        // It is a root-only option: after a command or agent (`acpx exec -V`),
        // acpx reports it as unknown, so only honour it at the root.
        if routing.flag("version"), routing.positionals.isEmpty {
            Console.out(ACPVersion.current + "\n")
            return ExitCodes.success
        }

        // `--help` / `-h`, or a leading `help` token, prints commander-style help
        // for the resolved command path and exits successfully.
        if routing.flag("help") || routing.positionals.first == "help" {
            var helpPath = routing.positionals
            if helpPath.first == "help" { helpPath.removeFirst() }
            Console.out(HelpRouter.render(
                path: helpPath, knownAgents: knownAgents, cwd: cwd,
                configAgents: Array(config.agents.keys)))
            return ExitCodes.success
        }

        var positionals = routing.positionals
        var explicitAgent: String?
        if let first = positionals.first, knownAgents.contains(AgentRegistry.normalize(first)) {
            explicitAgent = AgentRegistry.normalize(first)
            positionals.removeFirst()
        }

        let command = positionals.first
        let validSubcommands = explicitAgent != nil ? agentSubcommands : topSubcommands

        // Agent with no recognized subcommand → bare prompt for that agent.
        if explicitAgent != nil, let command, !validSubcommands.contains(command) {
            let context = CommandContext(
                explicitAgent: explicitAgent, positionals: positionals, rawArgs: rawArgs, config: config)
            return try PromptCommand.run(context)
        }

        guard let command, validSubcommands.contains(command) else {
            if explicitAgent != nil {
                // `acpx codex` with nothing else → prompt with empty input (errors).
                let context = CommandContext(
                    explicitAgent: explicitAgent, positionals: positionals, rawArgs: rawArgs,
                    config: config)
                return try PromptCommand.run(context)
            }
            if let command {
                throw UsageError("unknown command '\(command)'")
            }
            Console.errLine("acpx \(ACPVersion.current)")
            return ExitCodes.usage
        }

        let rest = Array(positionals.dropFirst())
        let context = CommandContext(
            explicitAgent: explicitAgent, positionals: rest, rawArgs: rawArgs, config: config)

        // The scanner and the value parsers throw without knowing which command
        // they were parsing for, so the help screen is attached here — the one
        // place that has resolved the path. `positionals` still carries the
        // subcommand's own path (`sessions list`), so a nested screen is reached.
        return try attachingUsage(
            path: (explicitAgent.map { [$0] } ?? []) + positionals,
            knownAgents: knownAgents, cwd: cwd, configAgents: Array(config.agents.keys)
        ) {
            try run(command, context)
        }
    }

    /// Run `body`, giving any `UsageError` it throws the help screen for `path`
    /// (commander's `showHelpAfterError()`). An error that already carries one
    /// keeps it — the inner command resolved a more specific path.
    private static func attachingUsage(
        path: [String], knownAgents: Set<String>, cwd: String, configAgents: [String],
        _ body: () throws -> Int32
    ) rethrows -> Int32 {
        do {
            return try body()
        } catch var error as UsageError {
            if error.usage == nil {
                let screen = error.scope == .root ? [] : path
                error.usage = HelpRouter.render(
                    path: screen, knownAgents: knownAgents, cwd: cwd, configAgents: configAgents)
            }
            throw error
        }
    }

    private static func run(_ command: String, _ context: CommandContext) throws -> Int32 {
        switch command {
        case "config": return try ConfigCommand.run(context)
        case "sessions": return try SessionsCommand.run(context)
        case "prompt": return try PromptCommand.run(context)
        case "exec": return try ExecCommand.run(context)
        case "cancel": return try ControlCommand.cancel(context)
        case "set-mode": return try ControlCommand.setMode(context)
        case "set": return try ControlCommand.set(context)
        case "status": return try StatusCommand.run(context)
        case "compare": return try CompareCommand.run(context)
        case "flow": return try FlowCommand.run(context)
        default: throw UsageError("unknown command '\(command)'")
        }
    }
}
