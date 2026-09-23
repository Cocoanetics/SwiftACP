import ACPXCore
import Foundation
import SwiftACP

enum SystemPromptOption: Sendable {
    case replace(String)
    case append(String)
}

/// Resolved global flags (acpx `GlobalFlags`).
struct GlobalFlags {
    var agent: String?
    var cwd: String
    var authPolicy: String
    var nonInteractivePermissions: String
    var permissionPolicy: String?
    var jsonStrict: Bool
    var suppressReads: Bool
    /// `--no-fs` / `--no-terminal`: whether the client advertises those capabilities.
    /// `nil` means the flag was not given, so the default applies.
    var fs: Bool?
    var terminal: Bool?
    var timeoutMs: Int?
    var ttlMs: Int
    var verbose: Bool
    var format: String
    var model: String?
    var allowedTools: [String]?
    var maxTurns: Int?
    var systemPrompt: SystemPromptOption?
    var promptRetries: Int?
    var approveAll: Bool
    var approveReads: Bool
    var denyAll: Bool
}

/// Resolved agent invocation (name + command + absolute cwd).
struct AgentInvocation {
    var agentName: String
    var agentCommand: String
    var cwd: String
}

enum Flags {
    /// The global option specs added by `addGlobalFlags`.
    static let globalSpecs: [OptionSpec] = [
        OptionSpec("agent", takesValue: true, value: "command"),
        OptionSpec("cwd", takesValue: true, value: "dir"),
        OptionSpec("auth-policy", takesValue: true, value: "policy"),
        OptionSpec("approve-all"),
        OptionSpec("approve-reads"),
        OptionSpec("deny-all"),
        OptionSpec("non-interactive-permissions", takesValue: true, value: "policy"),
        OptionSpec("permission-policy", takesValue: true, value: "json-or-file"),
        OptionSpec("policy", takesValue: true, value: "json-or-file"),
        OptionSpec("format", takesValue: true, value: "fmt"),
        OptionSpec("suppress-reads"),
        OptionSpec("model", takesValue: true, value: "id"),
        OptionSpec("allowed-tools", takesValue: true, value: "list"),
        OptionSpec("max-turns", takesValue: true, value: "count"),
        OptionSpec("system-prompt", takesValue: true, value: "text"),
        OptionSpec("append-system-prompt", takesValue: true, value: "text"),
        OptionSpec("prompt-retries", takesValue: true, value: "count"),
        OptionSpec("json-strict"),
        OptionSpec("fs", negatable: true),
        OptionSpec("terminal", negatable: true),
        OptionSpec("timeout", takesValue: true, value: "seconds"),
        OptionSpec("ttl", takesValue: true, value: "seconds"),
        // Consumed by `Router.dispatch` when loading config (it must be known before
        // any flag resolution); listed here so it scans as a known global option.
        OptionSpec("mcp-config", takesValue: true, value: "path"),
        OptionSpec("verbose"),
        OptionSpec("help", short: "h")
    ]

    static func resolveGlobalFlags(_ args: ScannedArgs, config: ResolvedAcpxConfig) throws -> GlobalFlags {
        let format = try args.parsed("format", parseOutputFormat)
            ?? parseOutputFormat(config.format)
        let jsonStrict = args.flag("json-strict")
        let verbose = args.flag("verbose")
        if jsonStrict && format != "json" {
            throw UsageError("--json-strict requires --format json")
        }
        if jsonStrict && verbose {
            throw UsageError("--json-strict cannot be combined with --verbose")
        }

        let permissionPolicy = try resolvePermissionPolicyOption(args)

        return GlobalFlags(
            agent: args.string("agent"),
            cwd: args.string("cwd") ?? physicalCWD(),
            authPolicy: try args.parsed("auth-policy", parseAuthPolicy) ?? config.authPolicy,
            nonInteractivePermissions: try args.parsed(
                "non-interactive-permissions", parseNonInteractivePermissionPolicy)
                ?? config.nonInteractivePermissions,
            permissionPolicy: permissionPolicy,
            jsonStrict: jsonStrict,
            suppressReads: args.flag("suppress-reads"),
            fs: args.boolean("fs"),
            terminal: args.boolean("terminal"),
            timeoutMs: try args.parsed("timeout", parseTimeoutSeconds) ?? config.timeoutMs,
            ttlMs: try args.parsed("ttl", parseTtlSeconds) ?? config.ttlMs,
            verbose: verbose,
            format: format,
            // Not a commander parser upstream — acpx validates the model later, so a
            // blank one prints bare (no `error:`, no help) and exits 2.
            model: try args.string("model").map { try nonEmptyRuntimeValue("Model", $0) },
            allowedTools: try args.parsed("allowed-tools", parseAllowedTools),
            maxTurns: try args.parsed("max-turns", parseMaxTurns),
            systemPrompt: try resolveSystemPrompt(args),
            promptRetries: try args.parsed("prompt-retries", parsePromptRetries),
            approveAll: args.flag("approve-all"),
            approveReads: args.flag("approve-reads"),
            denyAll: args.flag("deny-all"))
    }

    static func resolvePermissionMode(_ flags: GlobalFlags, default defaultMode: String) throws -> String {
        let count = [flags.approveAll, flags.approveReads, flags.denyAll].count(where: { $0 })
        if count > 1 {
            throw UsageError("Use only one permission mode: --approve-all, --approve-reads, or --deny-all")
        }
        if flags.approveAll { return "approve-all" }
        if flags.approveReads { return "approve-reads" }
        if flags.denyAll { return "deny-all" }
        return defaultMode
    }

    static func resolveAgentInvocation(
        _ explicitAgentName: String?, _ flags: GlobalFlags, config: ResolvedAcpxConfig
    ) throws -> AgentInvocation {
        // An explicit but blank `--agent` is a rejection upstream, not "no override":
        // validated outside commander, so bare and `EXIT_CODES.USAGE`.
        let override = try flags.agent.map { try nonEmptyRuntimeValue("Agent command", $0) }
        if let override, !override.isEmpty, explicitAgentName != nil {
            throw UsageError("Do not combine positional agent with --agent override")
        }
        let agentName = explicitAgentName ?? config.defaultAgent
        let agentCommand: String
        if let override, !override.isEmpty {
            agentCommand = override
        } else {
            agentCommand = AgentRegistry.command(for: agentName, overrides: config.agents) ?? agentName
        }
        return AgentInvocation(
            agentName: agentName,
            agentCommand: agentCommand,
            cwd: ACPXPaths.resolve(flags.cwd, base: physicalCWD()))
    }

    private static func resolvePermissionPolicyOption(_ args: ScannedArgs) throws -> String? {
        let primary = args.string("permission-policy")
        let alias = args.string("policy")
        if let primary, let alias, primary != alias {
            throw UsageError("Use only one permission policy flag: --permission-policy or --policy")
        }
        return primary ?? alias
    }

    private static func resolveSystemPrompt(_ args: ScannedArgs) throws -> SystemPromptOption? {
        let replace = try args.string("system-prompt").map { try parseNonEmptyValue("System prompt", $0) }
        let append = try args.string("append-system-prompt").map {
            try parseNonEmptyValue("Append system prompt", $0)
        }
        if replace != nil && append != nil {
            throw UsageError("Use only one of --system-prompt or --append-system-prompt")
        }
        if let replace { return .replace(replace) }
        if let append { return .append(append) }
        return nil
    }
}

// MARK: - Value parsers (acpx flags.ts; exact error messages)

func parseOutputFormat(_ value: String) throws -> String {
    guard ["text", "json", "quiet"].contains(value) else {
        throw UsageError("Invalid format \"\(value)\". Expected one of: text, json, quiet")
    }
    return value
}

func parseAuthPolicy(_ value: String) throws -> String {
    guard ["skip", "fail"].contains(value) else {
        throw UsageError("Invalid auth policy \"\(value)\". Expected one of: skip, fail")
    }
    return value
}

func parseNonInteractivePermissionPolicy(_ value: String) throws -> String {
    guard ["deny", "fail"].contains(value) else {
        throw UsageError(
            "Invalid non-interactive permission policy \"\(value)\". Expected one of: deny, fail")
    }
    return value
}

func parseTimeoutSeconds(_ value: String) throws -> Int {
    guard let n = Double(value), n.isFinite, n > 0 else {
        throw UsageError("Timeout must be a positive number of seconds")
    }
    return Int((n * 1000).rounded())
}

func parseTtlSeconds(_ value: String) throws -> Int {
    guard let n = Double(value), n.isFinite, n >= 0 else {
        throw UsageError("TTL must be a non-negative number of seconds")
    }
    return Int((n * 1000).rounded())
}

func parseSessionName(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw UsageError("Session name must not be empty") }
    return trimmed
}

func parseNonEmptyValue(_ label: String, _ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw UsageError("\(label) must not be empty") }
    return trimmed
}

extension GlobalFlags {
    /// `--non-interactive-permissions` as the library's policy; the parser has already
    /// rejected anything but `deny` and `fail`.
    var nonInteractivePolicy: NonInteractivePermissionPolicy {
        NonInteractivePermissionPolicy(rawValue: nonInteractivePermissions) ?? .deny
    }
}

/// acpx's `parseSessionConfigOptionAssignment`: split on the first `=`, which
/// may be neither the first nor the last character, then trim both halves and
/// require both to survive the trim.
func parseSessionConfigOptionAssignment(
    _ value: String
) throws -> ModelApplication.ConfigOptionAssignment {
    let malformed = UsageError(#"Session config option must use "<key>=<value>" with non-empty parts"#)
    guard let separator = value.firstIndex(of: "="), separator != value.startIndex,
        value.index(after: separator) != value.endIndex
    else { throw malformed }
    let configId = value[..<separator].trimmingCharacters(in: .whitespaces)
    let optionValue = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
    guard !configId.isEmpty, !optionValue.isEmpty else { throw malformed }
    return ModelApplication.ConfigOptionAssignment(configId: configId, value: optionValue)
}

func parseHistoryLimit(_ value: String) throws -> Int {
    guard let n = Int(value), n > 0 else { throw UsageError("Limit must be a positive integer") }
    return n
}

func parseDaysOlderThan(_ value: String) throws -> Int {
    guard let n = Int(value), n > 0 else {
        throw UsageError("--older-than must be a positive integer number of days")
    }
    return n
}

func parseAllowedTools(_ value: String) throws -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return [] }
    let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    if parts.contains(where: \.isEmpty) {
        throw UsageError("Allowed tools must be a comma-separated list without empty entries")
    }
    return parts
}

func parseMaxTurns(_ value: String) throws -> Int {
    guard let n = Int(value), n > 0 else { throw UsageError("Max turns must be a positive integer") }
    return n
}

func parsePromptRetries(_ value: String) throws -> Int {
    guard let n = Int(value), n >= 0 else {
        throw UsageError("Prompt retries must be a non-negative integer")
    }
    return n
}

extension GlobalFlags {
    /// What this invocation advertises in `initialize`. `--no-fs` withholds both
    /// filesystem methods and `--no-terminal` the terminal capability — and the client
    /// then refuses those methods if an agent calls them anyway, which is what acpx
    /// means by keeping registered methods aligned with the advertised capabilities.
    var clientCapabilities: ClientCapabilities {
        var capabilities = ClientCapabilities.headlessController
        if fs == false {
            capabilities.fs = FileSystemCapability(readTextFile: false, writeTextFile: false)
        }
        if terminal == false { capabilities.terminal = false }
        return capabilities
    }
}

/// A value acpx validates outside commander: rejected with a bare message and
/// `EXIT_CODES.USAGE`, with no `error:` prefix and no help screen.
func nonEmptyRuntimeValue(_ label: String, _ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
        throw CLIError("\(label) must not be empty", code: ExitCodes.usage)
    }
    return trimmed
}
