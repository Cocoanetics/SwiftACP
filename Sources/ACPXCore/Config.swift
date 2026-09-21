import Foundation
import JSONFoundation
import SwiftACP

// Defaults (config.ts).
public let DEFAULT_PERMISSION_MODE = "approve-reads"
public let DEFAULT_NON_INTERACTIVE_PERMISSION_POLICY = "deny"
public let DEFAULT_AUTH_POLICY = "skip"
public let DEFAULT_TTL_MS = 300_000
public let DEFAULT_QUEUE_MAX_DEPTH = 16
public let DEFAULT_OUTPUT_FORMAT = "text"

/// The raw shape of `~/.acpx/config.json` / `.acpxrc.json`. All fields optional.
public struct ACPXConfigFile: Codable, Sendable {
    public var defaultAgent: String?
    public var defaultPermissions: String?
    public var nonInteractivePermissions: String?
    public var authPolicy: String?
    public var ttl: Double?
    public var timeout: Double?
    public var queueMaxDepth: Int?
    public var format: String?
    public var agents: [String: AgentEntry]?
    public var auth: [String: String]?
    public var disableExec: Bool?
    public var mcpServers: [McpServerConfig]?

    /// A custom agent definition: launch command plus optional arguments.
    public struct AgentEntry: Codable, Sendable {
        public var command: String
        public var args: [String]?
    }
}

/// Normalizing the config-shaped `McpServerConfig` (a flat stdio/http/sse union,
/// shared with the daemon's tool DTOs in `SwiftACP`) to the ACP wire shape.
extension McpServerConfig {
    /// Normalize the config shape to the ACP wire shape, matching npm acpx.
    public func protocolSpec() throws -> MCPServerSpec {
        let name = try nonEmpty(name, field: "name")
        let type = try self.type.map { try nonEmpty($0, field: "type") } ?? "stdio"
        switch type {
        case "stdio":
            guard let command else {
                throw ConfigError("Invalid mcpServers entry \(name): missing command")
            }
            return .stdio(
                StdioMCPServer(
                    name: name, command: try nonEmpty(command, field: "command"),
                    args: args ?? [], env: try environmentVariables(env),
                    meta: meta.map { .object($0) }))
        case "http", "sse":
            guard let url else {
                throw ConfigError("Invalid mcpServers entry \(name): missing url")
            }
            var value: [String: JSONValue] = [
                "type": .string(type),
                "name": .string(name),
                "url": .string(try nonEmpty(url, field: "url")),
                "headers": .array(
                    try environmentVariables(headers).map {
                        .object(["name": .string($0.name), "value": .string($0.value)])
                    })
            ]
            if let meta { value["_meta"] = .object(meta) }
            return .other(.object(value))
        default:
            throw ConfigError("Invalid mcpServers entry \(name): expected type stdio, http, or sse")
        }
    }

    private func environmentVariables(_ entries: [EnvEntry]?) throws -> [EnvVariable] {
        try (entries ?? []).map {
            EnvVariable(
                name: try nonEmpty($0.name, field: "name"),
                value: try nonEmpty($0.value, field: "value"))
        }
    }

    private func nonEmpty(_ value: String, field: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ConfigError("Invalid mcpServers entry \(name): empty \(field)")
        }
        return value
    }
}

extension ResolvedAcpxConfig {
    /// MCP servers normalized for `session/new`, `session/load`, and `session/resume`.
    public func mcpServerSpecs() throws -> [MCPServerSpec] {
        try mcpServers.map { try $0.protocolSpec() }
    }

    /// The servers an explicit `--mcp-config` file supplies for *this session* —
    /// persisted on a record created under it so the daemon replays them on every
    /// reconnect — or `nil` when the invocation relies on the config-file servers.
    public var sessionMcpServers: [McpServerConfig]? {
        mcpConfigPath == nil ? nil : mcpServers
    }
}

/// The fully-resolved configuration (merge of global + project + defaults).
public struct ResolvedAcpxConfig: Sendable {
    public var defaultAgent: String
    public var defaultPermissions: String
    public var nonInteractivePermissions: String
    public var authPolicy: String
    public var ttlMs: Int
    public var timeoutMs: Int?
    public var queueMaxDepth: Int
    public var format: String
    public var agents: [String: String]
    public var auth: [String: String]
    public var disableExec: Bool
    public var mcpServers: [McpServerConfig]
    public var globalPath: String
    public var projectPath: String
    /// The `--mcp-config` file whose `mcpServers` replaced the config-file ones
    /// (absolute), or `nil` when none was given.
    public var mcpConfigPath: String?
    public var hasGlobalConfig: Bool
    public var hasProjectConfig: Bool
}

/// An unreadable/invalid config file, with a user-facing message.
public struct ConfigError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Reads `~/.acpx/config.json` and `<cwd>/.acpxrc.json` and merges them into a
/// ``ResolvedAcpxConfig``.
public enum ConfigLoader {
    /// Load + resolve config for `cwd` (defaults applied, project over global).
    ///
    /// - Parameter mcpConfigPath: an explicit `--mcp-config` file (relative paths
    ///   resolve from `cwd`). Its `mcpServers` array *replaces* the project/global
    ///   one for this invocation, matching npm acpx; the file must exist and carry
    ///   that array.
    public static func load(cwd: String, mcpConfigPath: String? = nil) throws -> ResolvedAcpxConfig {
        let globalPath = ACPXPaths.globalConfigPath
        let projectPath = ACPXPaths.projectConfigPath(cwd: cwd)
        let global = try readFile(globalPath)
        let project = try readFile(projectPath)
        let explicitMcp = try mcpConfigPath.map { try loadExplicitMcpServers($0, cwd: cwd) }

        let agents = mergeAgents(global?.agents, project?.agents)
        let auth = (global?.auth ?? [:]).merging(project?.auth ?? [:]) { _, new in new }

        return ResolvedAcpxConfig(
            defaultAgent: AgentRegistry.normalize(
                project?.defaultAgent ?? global?.defaultAgent ?? AgentRegistry.defaultAgent),
            defaultPermissions: project?.defaultPermissions ?? global?.defaultPermissions
                ?? DEFAULT_PERMISSION_MODE,
            nonInteractivePermissions: project?.nonInteractivePermissions
                ?? global?.nonInteractivePermissions ?? DEFAULT_NON_INTERACTIVE_PERMISSION_POLICY,
            authPolicy: project?.authPolicy ?? global?.authPolicy ?? DEFAULT_AUTH_POLICY,
            ttlMs: msFromSeconds(project?.ttl ?? global?.ttl) ?? DEFAULT_TTL_MS,
            timeoutMs: msFromSeconds(project?.timeout ?? global?.timeout),
            queueMaxDepth: project?.queueMaxDepth ?? global?.queueMaxDepth ?? DEFAULT_QUEUE_MAX_DEPTH,
            format: project?.format ?? global?.format ?? DEFAULT_OUTPUT_FORMAT,
            agents: agents,
            auth: auth,
            disableExec: project?.disableExec ?? global?.disableExec ?? false,
            mcpServers: explicitMcp?.servers ?? project?.mcpServers ?? global?.mcpServers ?? [],
            globalPath: globalPath.path,
            projectPath: projectPath.path,
            mcpConfigPath: explicitMcp?.path,
            hasGlobalConfig: global != nil,
            hasProjectConfig: project != nil)
    }

    private static func readFile(_ url: URL) throws -> ACPXConfigFile? {
        guard let data = try? Data(contentsOf: url) else { return nil } // ENOENT → not an error
        do {
            return try JSONDecoder().decode(ACPXConfigFile.self, from: data)
        } catch {
            throw ConfigError("Invalid config in \(url.path): \(error.localizedDescription)")
        }
    }

    /// Read a `--mcp-config` file: a JSON object whose top-level `mcpServers` array
    /// has the config-file entry shape. Unlike the config files, it is an error for
    /// it to be missing or to lack the array (npm acpx's `parseMcpServers` message).
    private static func loadExplicitMcpServers(
        _ rawPath: String, cwd: String
    ) throws -> (path: String, servers: [McpServerConfig]) {
        let path = ACPXPaths.resolve(rawPath, base: cwd)
        guard let file = try readFile(URL(fileURLWithPath: path)), let servers = file.mcpServers else {
            throw ConfigError("Invalid mcpServers in \(path): expected array")
        }
        return (path, servers)
    }

    private static func msFromSeconds(_ seconds: Double?) -> Int? {
        guard let seconds else { return nil }
        return Int((seconds * 1000).rounded())
    }

    /// Shallow merge `{...global, ...project}`, normalize keys, flatten to command strings.
    private static func mergeAgents(
        _ global: [String: ACPXConfigFile.AgentEntry]?,
        _ project: [String: ACPXConfigFile.AgentEntry]?
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (name, entry) in global ?? [:] {
            result[AgentRegistry.normalize(name)] = flatten(entry)
        }
        for (name, entry) in project ?? [:] {
            result[AgentRegistry.normalize(name)] = flatten(entry)
        }
        return result
    }

    private static func flatten(_ entry: ACPXConfigFile.AgentEntry) -> String {
        let command = entry.command.trimmingCharacters(in: .whitespaces)
        guard let args = entry.args, !args.isEmpty else { return command }
        let quoted = args.map { jsonQuote($0) }.joined(separator: " ")
        return "\(command) \(quoted)"
    }

    /// `JSON.stringify(value)` for a string — double-quoted with JSON escaping.
    private static func jsonQuote(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\"\(value)\""
    }
}
