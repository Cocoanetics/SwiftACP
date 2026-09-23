import ACPXCore
import Foundation
import SwiftACP

/// What a command handler gets: the agent it was reached through (if any), its path
/// below that, its arguments, the options given along the way, and the config.
struct CommandContext {
    var explicitAgent: String?
    /// The command below the agent: `["sessions", "list"]`, `["exec"]`, or empty for
    /// a bare prompt.
    var path: [String]
    /// The command's arguments.
    var positionals: [String]
    var config: ResolvedAcpxConfig
    /// The commands on the parsed path, root first, with the options given to each.
    var levels: [Commander.Level]

    /// The options as acpx's handlers read them. Below the root, a command's own value
    /// wins over the same option on its parent — acpx's `resolveCommandOption`, for
    /// `-s`, `--no-wait`, `-f` and the `sessions list` flags. The root's global options
    /// then overwrite the rest, as commander's `optsWithGlobals()` has it.
    var options: ScannedArgs {
        var merged = ScannedArgs()
        func take(_ key: String, from options: ScannedArgs) {
            merged.values[key] = options.values[key]
            merged.repeated[key] = options.repeated[key]
            merged.specs[key] = options.specs[key]
        }
        for level in levels.dropFirst().reversed() {
            for key in level.options.values.keys where merged.values[key] == nil {
                take(key, from: level.options)
            }
        }
        if let root = levels.first {
            for key in root.options.values.keys { take(key, from: root.options) }
        }
        return merged
    }

    /// The options given to the command itself, as acpx's handlers read their own
    /// `flags` (`compare --cwd`).
    var ownOptions: ScannedArgs { levels.last?.options ?? ScannedArgs() }

    func globalFlags() throws -> GlobalFlags {
        try Flags.resolveGlobalFlags(options, config: config)
    }
}

enum Router {
    static func dispatch(_ rawArgs: [String]) throws -> Int32 {
        // Before any config: `-V` works even when the config is broken.
        if LeadingFlags.isVersionRequest(rawArgs) {
            Console.out(ACPVersion.current + "\n")
            return ExitCodes.success
        }
        // acpx loads the config once, from the leading `--cwd` (or `compare`'s own) and
        // the leading `--mcp-config` — before commander has parsed anything.
        let base = physicalCWD()
        let config = try ConfigLoader.load(
            cwd: LeadingFlags.initialCwd(rawArgs, base: base), mcpConfigPath: LeadingFlags.mcpConfigPath(rawArgs))
        let agents = CommandTree.agentNames(config: config, arguments: rawArgs)
        let help = HelpContext(agents: agents, config: config, quiet: LeadingFlags.jsonStrict(rawArgs))

        let outcome: Commander.Outcome
        do {
            outcome = try Commander.parse(rawArgs, root: CommandTree.acpx(agents: agents))
        } catch var error as UsageError {
            error.usage = help.render(error.path)
            throw error
        }
        switch outcome {
        case .version:
            if !help.quiet { Console.out(ACPVersion.current + "\n") }
            return ExitCodes.success
        case .help(let path):
            if !help.quiet { Console.out(help.render(path)) }
            return ExitCodes.success
        case .helpAsError(let path):
            if !help.quiet { Console.err(help.render(path)) }
            return ExitCodes.error
        case .run(let levels, let arguments):
            return try run(levels: levels, arguments: arguments, config: config, help: help)
        }
    }

    /// The help screens a parse may show: they list the agents and the cwd.
    struct HelpContext {
        var agents: [String]
        var config: ResolvedAcpxConfig
        /// `--json-strict`: commander's output is suppressed.
        var quiet: Bool

        func render(_ path: [String]) -> String {
            HelpRouter.render(
                path: path, knownAgents: Set(agents), cwd: physicalCWD(), configAgents: config.agentOrder)
        }
    }

    private static func run(
        levels: [Commander.Level], arguments: [String], config: ResolvedAcpxConfig, help: HelpContext
    ) throws -> Int32 {
        var path = levels.dropFirst().map(\.spec.name)
        var explicitAgent: String?
        if levels.count > 1, levels[1].spec.passThrough {
            explicitAgent = AgentRegistry.normalize(path.removeFirst())
        }
        let context = CommandContext(
            explicitAgent: explicitAgent, path: path, positionals: arguments, config: config, levels: levels)
        guard let command = path.first else {
            // The root's action with no prompt and a terminal on stdin shows the help —
            // or, under `--json-strict`, refuses.
            if explicitAgent == nil, arguments.isEmpty, isatty(STDIN_FILENO) != 0 {
                if help.quiet {
                    throw InvalidArgumentError("Prompt is required (pass as argument, --file, or pipe via stdin)")
                }
                Console.out(help.render([]))
                return ExitCodes.success
            }
            return try PromptCommand.run(context)
        }
        do {
            return try run(command, context)
        } catch let error as UsageError {
            // Once a command runs, a refused value is acpx's `InvalidArgumentError` from
            // an action: reported as `USAGE`, not as a parse error.
            throw InvalidArgumentError(error.message)
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
        default: throw InvalidArgumentError("unknown command '\(command)'")
        }
    }

}
