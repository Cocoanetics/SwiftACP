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

    public struct AgentEntry: Codable, Sendable {
        public var command: String
        public var args: [String]?
    }
}

/// An MCP server entry (stdio/http/sse) — a flat Codable union.
public struct McpServerConfig: Codable, Sendable {
    public var type: String?
    public var name: String
    public var command: String?
    public var args: [String]?
    public var env: [EnvEntry]?
    public var url: String?
    public var headers: [EnvEntry]?
    public var meta: JSONValue?

    public struct EnvEntry: Codable, Sendable {
        public var name: String
        public var value: String
    }
    enum CodingKeys: String, CodingKey {
        case type, name, command, args, env, url, headers
        case meta = "_meta"
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
    public var hasGlobalConfig: Bool
    public var hasProjectConfig: Bool
}

public struct ConfigError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum ConfigLoader {
    /// Load + resolve config for `cwd` (defaults applied, project over global).
    public static func load(cwd: String) throws -> ResolvedAcpxConfig {
        let globalPath = ACPXPaths.globalConfigPath
        let projectPath = ACPXPaths.projectConfigPath(cwd: cwd)
        let global = try readFile(globalPath)
        let project = try readFile(projectPath)

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
            mcpServers: project?.mcpServers ?? global?.mcpServers ?? [],
            globalPath: globalPath.path,
            projectPath: projectPath.path,
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
