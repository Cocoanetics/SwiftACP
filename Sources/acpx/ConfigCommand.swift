import ACPXCore
import Foundation
import JSONFoundation

/// `acpx config [show|init]` — inspect and initialize configuration.
enum ConfigCommand {
    static func run(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([])
        let flags = try context.globalFlags(scan)
        let sub = context.positionals.first ?? "show"
        switch sub {
        case "show": return show(context.config, format: flags.format)
        case "init": return try initConfig(format: flags.format)
        default: throw UsageError("unknown command '\(sub)'")
        }
    }

    private static func show(_ config: ResolvedAcpxConfig, format: String) -> Int32 {
        let payload = document(config)
        Console.out((format == "json" ? payload.compact() : payload.pretty()) + "\n")
        return ExitCodes.success
    }

    /// acpx's `toConfigDisplay` with the paths and what loaded, in its order. The TTL and
    /// timeout are seconds as JavaScript divides them (`500` ms is `0.5`).
    static func document(_ config: ResolvedAcpxConfig) -> WireJSON {
        jsonObject([
            ("defaultAgent", .text(config.defaultAgent)),
            ("defaultPermissions", .text(config.defaultPermissions)),
            ("nonInteractivePermissions", .text(config.nonInteractivePermissions)),
            ("authPolicy", .text(config.authPolicy)),
            ("ttl", .number(Double(config.ttlMs) / 1000)),
            ("timeout", config.timeoutMs.map { WireJSON.number(Double($0) / 1000) } ?? .null),
            ("queueMaxDepth", .integer(config.queueMaxDepth)),
            ("format", .text(config.format)),
            ("agents", agentsDisplay(config)),
            ("authMethods", .array(config.auth.keys.sorted().map(WireJSON.text))),
            ("disableExec", .bool(config.disableExec)),
            // `mcp` (the explicit `--mcp-config` path) appears only when one was given.
            ("paths", jsonObject([
                ("global", .text(config.globalPath)),
                ("project", .text(config.projectPath)),
                ("mcp", config.mcpConfigPath.map(WireJSON.text))
            ] as [(String, WireJSON?)])),
            ("loaded", jsonObject([
                ("global", .bool(config.hasGlobalConfig)),
                ("project", .bool(config.hasProjectConfig))
            ] as [(String, WireJSON?)]))
        ] as [(String, WireJSON?)])
    }

    /// The agents in config order, as acpx's merged object lists them.
    private static func agentsDisplay(_ config: ResolvedAcpxConfig) -> WireJSON {
        jsonObject(config.agentOrder.compactMap { name in
            config.agents[name].map { command in
                (name, jsonObject([("command", .text(command))] as [(String, WireJSON?)]))
            }
        } as [(String, WireJSON?)])
    }

    private static func initConfig(format: String) throws -> Int32 {
        let path = ACPXPaths.globalConfigPath
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        let created: Bool
        if FileManager.default.fileExists(atPath: path.path) {
            created = false
        } else {
            let template = jsonObject([
                ("defaultAgent", .text("codex")),
                ("defaultPermissions", .text("approve-all")),
                ("nonInteractivePermissions", .text("deny")),
                ("authPolicy", .text("skip")),
                ("ttl", .integer(300)),
                ("timeout", .null),
                ("queueMaxDepth", .integer(16)),
                ("format", .text("text")),
                ("agents", .object([])),
                ("auth", .object([]))
            ] as [(String, WireJSON?)])
            try Data((template.pretty() + "\n").utf8).write(to: path)
            created = true
        }

        switch format {
        case "json":
            Console.out(
                jsonObject([("path", .string(path.path)), ("created", .bool(created))]).compact()
                    + "\n")
        case "quiet":
            Console.out(path.path + "\n")
        default:
            Console.out((created ? "Created \(path.path)" : "Config already exists: \(path.path)") + "\n")
        }
        return ExitCodes.success
    }
}
