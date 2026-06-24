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

    func globalFlags(_ scan: ScannedArgs) throws -> GlobalFlags {
        try Flags.resolveGlobalFlags(scan, config: config)
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
            OptionSpec("session", short: "s", takesValue: true),
            OptionSpec("file", short: "f", takesValue: true),
            OptionSpec("name", takesValue: true),
            OptionSpec("resume-session", takesValue: true),
            OptionSpec("cursor", takesValue: true),
            OptionSpec("filter-cwd", takesValue: true),
            OptionSpec("limit", takesValue: true),
            OptionSpec("tail", takesValue: true),
            OptionSpec("output", takesValue: true),
            OptionSpec("before", takesValue: true),
            OptionSpec("older-than", takesValue: true),
            OptionSpec("prompt-file", takesValue: true),
            OptionSpec("input-json", takesValue: true),
            OptionSpec("input-file", takesValue: true),
            OptionSpec("default-agent", takesValue: true),
            OptionSpec("local"),
            OptionSpec("dry-run"),
            OptionSpec("include-history"),
            OptionSpec("json"),
            OptionSpec("wait", negatable: true),
            OptionSpec("version", short: "V")
        ]

    static func dispatch(_ rawArgs: [String]) throws -> Int32 {
        let routing = try ArgScanner.scan(rawArgs, options: routingSpecs)
        let cwd = routing.string("cwd") ?? physicalCWD()
        let config = try ConfigLoader.load(cwd: cwd)
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
            Console.out(HelpRouter.render(path: helpPath, knownAgents: knownAgents, cwd: cwd))
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
