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
            // The name is trimmed and must be non-empty; the value is taken verbatim.
            // An empty value and one carrying significant whitespace are both legitimate
            // — acpx's `parseNonEmptyString` for the name, `parseString` for the value.
            EnvVariable(name: try nonEmpty($0.name, field: "name"), value: $0.value)
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
    /// The names in ``agents`` in the order acpx lists them: its merge is a JavaScript
    /// object spread (`{...global, ...project}`), so global agents come in file order,
    /// then project-only ones in theirs, and a name in both keeps its global place.
    public var agentOrder: [String]
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
///
/// `LocalizedError` so the message survives `localizedDescription` — config errors
/// are thrown before a command runs (e.g. a bad `--mcp-config`), where the CLI's
/// catch-all prints exactly that, and would otherwise show Foundation's opaque
/// "The operation couldn't be completed" text.
public struct ConfigError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Reads `~/.acpx/config.json` and `<cwd>/.acpxrc.json` and merges them into a
/// ``ResolvedAcpxConfig``.
public enum ConfigLoader {
    /// Load + resolve config for `cwd` (defaults applied, project over global), as
    /// acpx's `loadResolvedConfig` does: each file must be JSON — as `JSON.parse` reads
    /// it — with an object at the top, and each field valid, or the whole load fails
    /// naming the field and the file.
    ///
    /// Fields resolve in acpx's order, project first: the project's value when it has
    /// one, else the global's, else the default — each checked only when reached, so a
    /// valid project value leaves the global one unchecked. Agents and auth merge like
    /// a JavaScript spread, `{...global, ...project}`.
    ///
    /// - Parameters:
    ///   - mcpConfigPath: an explicit `--mcp-config` file (relative paths resolve from
    ///     `cwd`). Its `mcpServers` array *replaces* the project/global one for this
    ///     invocation, matching npm acpx; the file must exist and carry that array.
    ///   - ownMcpServers: the caller brings its own servers (the daemon's tools), which
    ///     replace the config files' — so theirs are neither read nor checked, as acpx
    ///     skips them under `--mcp-config`.
    public static func load(
        cwd: String, mcpConfigPath: String? = nil, ownMcpServers: Bool = false
    ) throws -> ResolvedAcpxConfig {
        let globalPath = ACPXPaths.globalConfigPath
        let projectPath = ACPXPaths.projectConfigPath(cwd: cwd)
        let global = try readFile(globalPath)
        let project = try readFile(projectPath)
        let explicitMcp = try mcpConfigPath.map { try readExplicitMcpFile($0, cwd: cwd) }

        func scalar<T>(_ key: String, _ parse: (WireJSON?, String) throws -> T?) throws -> T? {
            if let project, let value = try parse(project[key], project.path) { return value }
            if let global, let value = try parse(global[key], global.path) { return value }
            return nil
        }
        typealias Fields = ConfigFields
        let defaultAgent = try scalar("defaultAgent", Fields.defaultAgent) ?? AgentRegistry.defaultAgent
        let defaultPermissions = try scalar("defaultPermissions") {
            try Fields.choice($0, $1, field: "defaultPermissions",
                              allowed: ["approve-all", "approve-reads", "deny-all"],
                              expected: "approve-all, approve-reads, or deny-all")
        } ?? DEFAULT_PERMISSION_MODE
        let nonInteractive = try scalar("nonInteractivePermissions") {
            try Fields.choice($0, $1, field: "nonInteractivePermissions", allowed: ["deny", "fail"],
                              expected: "deny or fail")
        } ?? DEFAULT_NON_INTERACTIVE_PERMISSION_POLICY
        let authPolicy = try scalar("authPolicy") {
            try Fields.choice($0, $1, field: "authPolicy", allowed: ["skip", "fail"], expected: "skip or fail")
        } ?? DEFAULT_AUTH_POLICY
        let ttlMs = try scalar("ttl", Fields.ttlMs) ?? DEFAULT_TTL_MS
        // A `timeout` key in the project — even `null` — settles it (`resolveTimeoutMs`).
        let timeoutMs: Int?
        if let project, project.has("timeout") {
            timeoutMs = try Fields.timeoutMs(project["timeout"], project.path)
        } else if let global, global.has("timeout") {
            timeoutMs = try Fields.timeoutMs(global["timeout"], global.path)
        } else {
            timeoutMs = nil
        }
        let queueMaxDepth = try scalar("queueMaxDepth", Fields.queueMaxDepth) ?? DEFAULT_QUEUE_MAX_DEPTH
        let format = try scalar("format") {
            try Fields.choice($0, $1, field: "format", allowed: ["text", "json", "quiet"],
                              expected: "text, json, or quiet")
        } ?? DEFAULT_OUTPUT_FORMAT

        let (agents, agentNames) = try mergedAgents(global, project)
        let auth = try mergedAuth(global, project)
        // `resolveMcpServers`: an explicit file's, else the project's, else the global's.
        let mcpServers: [McpServerConfig]
        if let explicitMcp {
            mcpServers = try Fields.mcpServers(explicitMcp["mcpServers"], explicitMcp.path)
        } else if ownMcpServers {
            mcpServers = []
        } else if let project, project.has("mcpServers") {
            mcpServers = try Fields.mcpServers(project["mcpServers"], project.path)
        } else if let global, global.has("mcpServers") {
            mcpServers = try Fields.mcpServers(global["mcpServers"], global.path)
        } else {
            mcpServers = []
        }
        let disableExec = try scalar("disableExec", Fields.disableExec) ?? false

        return ResolvedAcpxConfig(
            defaultAgent: defaultAgent,
            defaultPermissions: defaultPermissions,
            nonInteractivePermissions: nonInteractive,
            authPolicy: authPolicy,
            ttlMs: ttlMs,
            timeoutMs: timeoutMs,
            queueMaxDepth: queueMaxDepth,
            format: format,
            agents: agents,
            agentOrder: WireJSON.propertyOrder(agentNames),
            auth: auth,
            disableExec: disableExec,
            mcpServers: mcpServers,
            globalPath: globalPath.path,
            projectPath: projectPath.path,
            mcpConfigPath: explicitMcp?.path,
            hasGlobalConfig: global != nil,
            hasProjectConfig: project != nil)
    }

    /// `{...parseAgents(global), ...parseAgents(project)}`: each file's agents in order,
    /// a name in both keeping its global place and taking the project's command.
    private static func mergedAgents(
        _ global: ConfigFields.File?, _ project: ConfigFields.File?
    ) throws -> (agents: [String: String], names: [String]) {
        var agents: [String: String] = [:]
        var names: [String] = []
        for file in [global, project].compactMap({ $0 }) {
            for (name, command) in try ConfigFields.agents(file["agents"], file.path) ?? [] {
                agents[name] = command
                names.append(name)
            }
        }
        return (agents, names)
    }

    /// `{...parseAuth(global), ...parseAuth(project)}`.
    private static func mergedAuth(
        _ global: ConfigFields.File?, _ project: ConfigFields.File?
    ) throws -> [String: String] {
        var auth: [String: String] = [:]
        for file in [global, project].compactMap({ $0 }) {
            for (methodId, credential) in try ConfigFields.auth(file["auth"], file.path) ?? [] {
                auth[methodId] = credential
            }
        }
        return auth
    }

    /// acpx's `readConfigFile`: a missing file is no config; one that cannot be read
    /// fails as Node's read does; the text must be JSON as `JSON.parse` reads it (a BOM
    /// included) and hold an object.
    private static func readFile(_ url: URL) throws -> ConfigFields.File? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if let failure = readFailure(error, path: url.path) { throw failure }
            return nil
        }
        let root: WireJSON
        do {
            root = try WireJSON.parse(String(decoding: data, as: UTF8.self))
        } catch let error as WireJSON.SyntaxError {
            throw ConfigError("Invalid JSON in \(url.path): \(error.message)")
        }
        guard case .object = root else {
            throw ConfigError("Invalid config in \(url.path): expected top-level JSON object")
        }
        return ConfigFields.File(path: url.path, root: root)
    }

    /// Node's message for a config file that exists but cannot be read; `nil` when it
    /// does not exist.
    private static func readFailure(_ error: Error, path: String) -> ConfigError? {
        let posix = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code
        switch posix.map({ POSIXErrorCode(rawValue: Int32($0)) }) {
        case .some(.EISDIR): return ConfigError("EISDIR: illegal operation on a directory, read")
        case .some(.EACCES): return ConfigError("EACCES: permission denied, open '\(path)'")
        default:
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return ConfigError("EISDIR: illegal operation on a directory, read")
            }
            return nil
        }
    }

    /// Read a `--mcp-config` file. Unlike the config files, a missing file is an error;
    /// its `mcpServers` are checked later, where acpx checks them.
    private static func readExplicitMcpFile(_ rawPath: String, cwd: String) throws -> ConfigFields.File {
        let path = ACPXPaths.resolve(rawPath, base: cwd)
        guard let file = try readFile(URL(fileURLWithPath: path)) else {
            throw ConfigError("MCP config file not found: \(path)")
        }
        return file
    }

}
