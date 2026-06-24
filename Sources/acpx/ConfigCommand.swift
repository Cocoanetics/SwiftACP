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
        let payload = jsonObject([
            ("defaultAgent", .string(config.defaultAgent)),
            ("defaultPermissions", .string(config.defaultPermissions)),
            ("nonInteractivePermissions", .string(config.nonInteractivePermissions)),
            ("authPolicy", .string(config.authPolicy)),
            ("ttl", .integer(Int((Double(config.ttlMs) / 1000).rounded()))),
            ("timeout", config.timeoutMs.map { JSONValue.double(Double($0) / 1000) } ?? .null),
            ("queueMaxDepth", .integer(config.queueMaxDepth)),
            ("format", .string(config.format)),
            ("agents", agentsDisplay(config.agents)),
            ("authMethods", .array(config.auth.keys.sorted().map { JSONValue.string($0) })),
            ("disableExec", .bool(config.disableExec)),
            ("paths", jsonObject([
                ("global", .string(config.globalPath)),
                ("project", .string(config.projectPath))
            ])),
            ("loaded", jsonObject([
                ("global", .bool(config.hasGlobalConfig)),
                ("project", .bool(config.hasProjectConfig))
            ]))
        ])
        Console.out((format == "json" ? payload.compact() : payload.pretty()) + "\n")
        return ExitCodes.success
    }

    private static func agentsDisplay(_ agents: [String: String]) -> JSONValue {
        jsonObject(agents.keys.sorted().map { name in
            (name, jsonObject([("command", .string(agents[name]!))]))
        })
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
                ("defaultAgent", .string("codex")),
                ("defaultPermissions", .string("approve-all")),
                ("nonInteractivePermissions", .string("deny")),
                ("authPolicy", .string("skip")),
                ("ttl", .integer(300)),
                ("timeout", .null),
                ("queueMaxDepth", .integer(16)),
                ("format", .string("text")),
                ("agents", jsonObject([])),
                ("auth", jsonObject([]))
            ])
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
