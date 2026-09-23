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
    /// The exact argv to launch, when there is one (see ``Flags/resolveAgentInvocation``).
    var agentArgv: [String]?
    var cwd: String
}

enum Flags {
    /// The global options `addGlobalFlags` puts on the root, with their parsers.
    /// `--no-fs` and `--no-terminal` exist only in that form.
    static let globalSpecs: [OptionSpec] = [
        OptionSpec("agent", takesValue: true, value: "command"),
        OptionSpec("cwd", takesValue: true, value: "dir"),
        OptionSpec("auth-policy", takesValue: true, value: "policy", validate: { _ = try parseAuthPolicy($0) }),
        OptionSpec("approve-all"),
        OptionSpec("approve-reads"),
        OptionSpec("deny-all"),
        OptionSpec(
            "non-interactive-permissions", takesValue: true, value: "policy",
            validate: { _ = try parseNonInteractivePermissionPolicy($0) }),
        OptionSpec("permission-policy", takesValue: true, value: "json-or-file"),
        OptionSpec("policy", takesValue: true, value: "json-or-file"),
        OptionSpec("format", takesValue: true, value: "fmt", validate: { _ = try parseOutputFormat($0) }),
        OptionSpec("suppress-reads"),
        OptionSpec("model", takesValue: true, value: "id"),
        OptionSpec("allowed-tools", takesValue: true, value: "list", validate: { _ = try parseAllowedTools($0) }),
        OptionSpec("max-turns", takesValue: true, value: "count", validate: { _ = try parseMaxTurns($0) }),
        OptionSpec(
            "system-prompt", takesValue: true, value: "text",
            validate: { _ = try parseNonEmptyValue("System prompt", $0) }),
        OptionSpec(
            "append-system-prompt", takesValue: true, value: "text",
            validate: { _ = try parseNonEmptyValue("Append system prompt", $0) }),
        OptionSpec(
            "prompt-retries", takesValue: true, value: "count", validate: { _ = try parsePromptRetries($0) }),
        OptionSpec("json-strict"),
        OptionSpec("no-fs"),
        OptionSpec("no-terminal"),
        OptionSpec("timeout", takesValue: true, value: "seconds", validate: { _ = try parseTimeoutSeconds($0) }),
        OptionSpec("ttl", takesValue: true, value: "seconds", validate: { _ = try parseTtlSeconds($0) }),
        // Read before the parse too (``LeadingFlags``): the config it names is loaded first.
        OptionSpec("mcp-config", takesValue: true, value: "path"),
        OptionSpec("verbose")
    ]

    static func resolveGlobalFlags(_ args: ScannedArgs, config: ResolvedAcpxConfig) throws -> GlobalFlags {
        let format = try args.parsed("format", parseOutputFormat)
            ?? parseOutputFormat(config.format)
        let jsonStrict = args.flag("json-strict")
        let verbose = args.flag("verbose")
        if jsonStrict && format != "json" {
            throw InvalidArgumentError("--json-strict requires --format json")
        }
        if jsonStrict && verbose {
            throw InvalidArgumentError("--json-strict cannot be combined with --verbose")
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
            fs: args.flag("no-fs") ? false : nil,
            terminal: args.flag("no-terminal") ? false : nil,
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
            throw InvalidArgumentError("Use only one permission mode: --approve-all, --approve-reads, or --deny-all")
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
            throw InvalidArgumentError("Do not combine positional agent with --agent override")
        }
        let agentName = explicitAgentName ?? config.defaultAgent
        // `--agent` is a command line to split; a name launches as acpx resolves it.
        let (agentCommand, agentArgv) = if let override, !override.isEmpty {
            (override, nil as [String]?)
        } else {
            config.agentLaunch(for: agentName)
        }
        return AgentInvocation(
            agentName: agentName,
            agentCommand: agentCommand,
            agentArgv: agentArgv,
            cwd: ACPXPaths.resolve(flags.cwd, base: physicalCWD()))
    }

    private static func resolvePermissionPolicyOption(_ args: ScannedArgs) throws -> String? {
        let primary = args.string("permission-policy")
        let alias = args.string("policy")
        if let primary, let alias, primary != alias {
            throw InvalidArgumentError("Use only one permission policy flag: --permission-policy or --policy")
        }
        return primary ?? alias
    }

    private static func resolveSystemPrompt(_ args: ScannedArgs) throws -> SystemPromptOption? {
        let replace = try args.string("system-prompt").map { try parseNonEmptyValue("System prompt", $0) }
        let append = try args.string("append-system-prompt").map {
            try parseNonEmptyValue("Append system prompt", $0)
        }
        if replace != nil && append != nil {
            throw InvalidArgumentError("Use only one of --system-prompt or --append-system-prompt")
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

// The numbers are JavaScript's (`Number(value)`), and the trimming its `trim()`.

func parseTimeoutSeconds(_ value: String) throws -> Int {
    let seconds = JavaScriptNumber.parse(value)
    guard seconds.isFinite, seconds > 0 else {
        throw UsageError("Timeout must be a positive number of seconds")
    }
    guard let milliseconds = JavaScriptNumber.timerMilliseconds(seconds, allowZero: false) else {
        throw UsageError("Timeout exceeds the maximum supported timer delay")
    }
    return milliseconds
}

func parseTtlSeconds(_ value: String) throws -> Int {
    let seconds = JavaScriptNumber.parse(value)
    guard seconds.isFinite, seconds >= 0 else {
        throw UsageError("TTL must be a non-negative number of seconds")
    }
    guard let milliseconds = JavaScriptNumber.timerMilliseconds(seconds, allowZero: true) else {
        throw UsageError("TTL exceeds the maximum supported timer delay")
    }
    return milliseconds
}

func parseSessionName(_ value: String) throws -> String {
    let trimmed = value.javaScriptTrimmed
    guard !trimmed.isEmpty else { throw UsageError("Session name must not be empty") }
    return trimmed
}

func parseNonEmptyValue(_ label: String, _ value: String) throws -> String {
    let trimmed = value.javaScriptTrimmed
    guard !trimmed.isEmpty else { throw UsageError("\(label) must not be empty") }
    return trimmed
}

/// A positive (or, with `allowZero`, non-negative) integer, as `Number.isInteger` has it.
private func parseCount(_ value: String, allowZero: Bool = false, _ message: String) throws -> Int {
    let number = JavaScriptNumber.parse(value)
    guard JavaScriptNumber.isInteger(number), allowZero ? number >= 0 : number > 0 else {
        throw UsageError(message)
    }
    return Int(exactly: number) ?? Int.max
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
    let configId = String(value[..<separator]).javaScriptTrimmed
    let optionValue = String(value[value.index(after: separator)...]).javaScriptTrimmed
    guard !configId.isEmpty, !optionValue.isEmpty else { throw malformed }
    return ModelApplication.ConfigOptionAssignment(configId: configId, value: optionValue)
}

func parseHistoryLimit(_ value: String) throws -> Int {
    try parseCount(value, "Limit must be a positive integer")
}

func parseDaysOlderThan(_ value: String) throws -> Int {
    try parseCount(value, "--older-than must be a positive integer number of days")
}

func parseAllowedTools(_ value: String) throws -> [String] {
    let trimmed = value.javaScriptTrimmed
    if trimmed.isEmpty { return [] }
    let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map { String($0).javaScriptTrimmed }
    if parts.contains(where: \.isEmpty) {
        throw UsageError("Allowed tools must be a comma-separated list without empty entries")
    }
    return parts
}

func parseMaxTurns(_ value: String) throws -> Int {
    try parseCount(value, "Max turns must be a positive integer")
}

func parsePromptRetries(_ value: String) throws -> Int {
    try parseCount(value, allowZero: true, "Prompt retries must be a non-negative integer")
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
    let trimmed = value.javaScriptTrimmed
    guard !trimmed.isEmpty else {
        throw CLIError("\(label) must not be empty", code: ExitCodes.usage)
    }
    return trimmed
}
