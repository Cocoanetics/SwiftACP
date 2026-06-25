import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `cancel`, `set-mode <mode>`, `set <key> <value>`.
enum ControlCommand {
    // MARK: cancel

    static func cancel(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([OptionSpec("session", short: "s", takesValue: true)])
        let flags = try context.globalFlags(scan)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.string("session").map(parseSessionName)
        let gitRoot = SessionStore.findGitRepositoryRoot(agent.cwd)
        let record = SessionStore.findSessionByDirectoryWalk(
            agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, boundary: gitRoot ?? agent.cwd)
        // An in-flight prompt is held by the daemon, so route the cancel there. If
        // no daemon is reachable (or the session isn't live) there's nothing to cancel.
        var cancelled = false
        if let record {
            cancelled = try runBlocking { await DaemonClient.cancelSession(sessionId: record.acpSessionId) }
        }
        printCancel(sessionId: record?.acpxRecordId ?? "", cancelled: cancelled, format: flags.format)
        return ExitCodes.success
    }

    private static func printCancel(sessionId: String, cancelled: Bool, format: String) {
        switch format {
        case "json":
            Console.out(jsonObject([
                ("action", .string("cancel_result")),
                ("acpxRecordId", .string(sessionId.isEmpty ? "unknown" : sessionId)),
                ("cancelled", .bool(cancelled))
            ]).compact() + "\n")
        default:
            Console.out(cancelled ? "cancel requested\n" : "nothing to cancel\n")
        }
    }

    // MARK: set-mode

    static func setMode(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([OptionSpec("session", short: "s", takesValue: true)])
        let flags = try context.globalFlags(scan)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.string("session").map(parseSessionName)
        guard let modeId = try context.positionals.first.map({ try parseNonEmptyValue("Mode", $0) }) else {
            throw UsageError("missing required argument 'mode'")
        }
        let record = try PromptCommand.findRoutedSessionOrThrow(agent: agent, name: name)
        let sessionId = record.acpSessionId

        // Route through acpxd — the single manager that holds the live agent and owns
        // its record — rather than launching a throwaway agent and writing the record
        // here (which would miss the live session and could clobber a concurrent turn).
        try runBlocking {
            do {
                try await DaemonClient.setMode(sessionId: sessionId, modeId: modeId)
            } catch let unavailable as DaemonUnavailable {
                throw CLIError(unavailable.cliMessage)
            }
        }
        // The daemon persisted the change; reload the record for output.
        let updated = SessionStore.loadRecord(record.acpxRecordId) ?? record
        printSetMode(modeId: modeId, record: updated, format: flags.format)
        return ExitCodes.success
    }

    private static func printSetMode(modeId: String, record: SessionRecord, format: String) {
        switch format {
        case "json":
            Console.out(jsonObject([
                ("action", .string("mode_set")),
                ("modeId", .string(modeId)),
                ("resumed", .bool(false)),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId)),
                ("agentSessionId", record.agentSessionId.map(JSONValue.string) ?? .null)
            ]).compact() + "\n")
        case "quiet":
            Console.out("\(modeId)\n")
        default:
            Console.out("mode set: \(modeId)\n")
        }
    }

    // MARK: set <key> <value>

    static func set(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([OptionSpec("session", short: "s", takesValue: true)])
        let flags = try context.globalFlags(scan)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        guard context.positionals.count >= 2 else {
            throw UsageError("missing required argument 'value'")
        }
        let key = try parseNonEmptyValue("Config option key", context.positionals[0])
        let value = try parseNonEmptyValue("Config option value", context.positionals[1])
        let name = try scan.string("session").map(parseSessionName)

        let record = try PromptCommand.findRoutedSessionOrThrow(agent: agent, name: name)
        // Mirror acpx's `handleSetConfigOption`: the `model` key drives
        // session/set_model (legacy control) or the model config option
        // (config_option control); other keys get the config-id compatibility
        // aliases applied + validated against the session's advertised options.
        let operation = resolveSetOperation(key: key, agentCommand: agent.agentCommand, record: record)
        let sessionId = record.acpSessionId

        // Route through acpxd — the single manager that holds the live agent and owns
        // its record — rather than launching a throwaway agent and writing the record
        // here. The set_config_option response carries the agent's updated config
        // options, which acpx reports + echoes in the JSON envelope.
        let resultOptions: [JSONValue] = try runBlocking {
            do {
                switch operation {
                case .model:
                    try await DaemonClient.setModel(sessionId: sessionId, modelId: value)
                    return []
                case .configOption(let configId):
                    return try await DaemonClient.setConfigOption(
                        sessionId: sessionId, configId: configId, value: value)
                }
            } catch let unavailable as DaemonUnavailable {
                throw CLIError(unavailable.cliMessage)
            }
        }

        // The daemon persisted the change; reload the record for output.
        let updated = SessionStore.loadRecord(record.acpxRecordId) ?? record
        switch operation {
        case .model:
            printSetModel(modelId: value, record: updated, format: flags.format)
        case .configOption:
            // acpx prints the user's original key, not the resolved config id.
            printSetConfig(
                key: key, value: value, configOptions: resultOptions, record: updated, format: flags.format)
        }
        return ExitCodes.success
    }

    private static func printSetConfig(
        key: String, value: String, configOptions: [JSONValue], record: SessionRecord, format: String
    ) {
        switch format {
        case "json":
            Console.out(jsonObject([
                ("action", .string("config_set")),
                ("configId", .string(key)),
                ("value", .string(value)),
                ("resumed", .bool(false)),
                ("configOptions", .array(configOptions)),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId)),
                ("agentSessionId", record.agentSessionId.map(JSONValue.string) ?? .null)
            ]).compact() + "\n")
        case "quiet":
            Console.out("\(value)\n")
        default:
            Console.out("config set: \(key)=\(value) (\(configOptions.count) options)\n")
        }
    }

    private static func printSetModel(modelId: String, record: SessionRecord, format: String) {
        switch format {
        case "json":
            Console.out(jsonObject([
                ("action", .string("model_set")),
                ("modelId", .string(modelId)),
                ("resumed", .bool(false)),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId)),
                ("agentSessionId", record.agentSessionId.map(JSONValue.string) ?? .null)
            ]).compact() + "\n")
        case "quiet":
            Console.out("\(modelId)\n")
        default:
            Console.out("model set: \(modelId)\n")
        }
    }

    // MARK: set routing (ported from acpx handleSetConfigOption / handleSetModel)

    private enum SetOperation {
        case model
        case configOption(String)
    }

    /// Decide whether `set <key> <value>` drives session/set_model or
    /// session/set_config_option. acpx routes the `model` key to session/set_model
    /// for legacy-control agents (codex) and to the `model` config option for
    /// config_option agents (claude); other keys pass through `resolveCompatibleConfigId`.
    private static func resolveSetOperation(
        key: String, agentCommand: String, record: SessionRecord
    ) -> SetOperation {
        if key == "model" {
            return record.acpx?.modelControl == "legacy_set_model" ? .model : .configOption("model")
        }
        return .configOption(resolveCompatibleConfigId(agentCommand: agentCommand, configId: key))
    }

    /// acpx `resolveCompatibleConfigId`: the legacy `@zed-industries/codex-acp`
    /// adapter named the reasoning-effort option `thought_level`; map it across.
    ///
    /// acpx's *other* alias (`thinking` → `effort`, `resolveSupportedConfigOptionId`)
    /// is intentionally not replicated: it only fires against a live session's
    /// advertised options, which acpx doesn't have when it maps the key before
    /// issuing the daemon call. acpx itself sends the key verbatim there, so
    /// `set thinking` fails identically in both (the agent rejects the unknown option).
    private static func resolveCompatibleConfigId(agentCommand: String, configId: String) -> String {
        if isLegacyZedCodexAcpInvocation(agentCommand), configId == "thought_level" {
            return "reasoning_effort"
        }
        return configId
    }

    private static func isLegacyZedCodexAcpInvocation(_ agentCommand: String) -> Bool {
        agentCommand.range(of: #"@zed-industries/codex-acp\b"#, options: .regularExpression) != nil
    }
}
