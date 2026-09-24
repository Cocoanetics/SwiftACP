import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `cancel`, `set-mode <mode>`, `set <key> <value>`.
enum ControlCommand {
    // MARK: cancel

    static func cancel(_ context: CommandContext) throws -> Int32 {
        let scan = context.options
        let flags = try context.globalFlags()
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.parsed("session", parseSessionName)
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
        let scan = context.options
        let flags = try context.globalFlags()
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.parsed("session", parseSessionName)
        // The parse has checked `<mode>` is there and not blank.
        let modeId = try parseNonEmptyValue("Mode", context.positionals[0])
        let record = try PromptCommand.findRoutedSessionOrThrow(agent: agent, name: name)
        let sessionId = record.acpSessionId
        // Checked here, as acpx checks it building its client; the daemon caps terminal
        // output by it while the agent answers.
        let terminalOutputCeiling = try TerminalOutputLimit.ceiling()

        // Route through acpxd — the single manager that holds the live agent and owns
        // its record — rather than launching a throwaway agent and writing the record
        // here (which would miss the live session and could clobber a concurrent turn).
        let result = try runBlocking {
            do {
                return try await DaemonClient.setMode(
                    sessionId: sessionId, modeId: modeId, terminalOutputCeiling: terminalOutputCeiling)
            } catch let unavailable as DaemonUnavailable {
                throw CLIError(unavailable.cliMessage)
            }
        }
        // The daemon persisted the change; reload the record for output.
        let updated = SessionStore.loadRecord(record.acpxRecordId) ?? record
        printSetMode(modeId: modeId, resumed: result.resumed, record: updated, format: flags.format)
        return ExitCodes.success
    }

    private static func printSetMode(modeId: String, resumed: Bool, record: SessionRecord, format: String) {
        switch format {
        case "json":
            Console.out(jsonObject([
                ("action", .string("mode_set")),
                ("modeId", .string(modeId)),
                ("resumed", .bool(resumed)),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId)),
                ("agentSessionId", record.agentSessionId.map(JSONValue.string))
            ]).compact() + "\n")
        case "quiet":
            Console.out("\(modeId)\n")
        default:
            Console.out("mode set: \(modeId)\n")
        }
    }

    // MARK: set <key> <value>

    static func set(_ context: CommandContext) throws -> Int32 {
        let scan = context.options
        let flags = try context.globalFlags()
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        // The parse has checked `<key>` and `<value>` are there and not blank.
        let key = try parseNonEmptyValue("Config option key", context.positionals[0])
        let value = try parseNonEmptyValue("Config option value", context.positionals[1])
        let name = try scan.parsed("session", parseSessionName)

        let record = try PromptCommand.findRoutedSessionOrThrow(agent: agent, name: name)
        // Mirror acpx's `handleSetConfigOption`: the `model` key drives
        // session/set_model (legacy control) or the model config option
        // (config_option control); other keys get the config-id compatibility
        // aliases applied + validated against the session's advertised options.
        let operation = resolveSetOperation(key: key, agentCommand: agent.agentCommand)
        let sessionId = record.acpSessionId
        let terminalOutputCeiling = try TerminalOutputLimit.ceiling()

        // Route through acpxd — the single manager that holds the live agent and owns
        // its record — rather than launching a throwaway agent and writing the record
        // here. The set_config_option response carries the agent's updated config
        // options, which acpx reports + echoes in the JSON envelope.
        let result: SessionControlResult = try runBlocking {
            do {
                switch operation {
                case .model:
                    return try await DaemonClient.setModel(
                        sessionId: sessionId, modelId: value, terminalOutputCeiling: terminalOutputCeiling)
                case .configOption(let configId):
                    return try await DaemonClient.setConfigOption(
                        sessionId: sessionId, configId: configId, value: value,
                        terminalOutputCeiling: terminalOutputCeiling)
                }
            } catch let unavailable as DaemonUnavailable {
                throw CLIError(unavailable.cliMessage)
            }
        }

        // The daemon persisted the change; reload the record for output.
        let updated = SessionStore.loadRecord(record.acpxRecordId) ?? record
        switch operation {
        case .model:
            printSetModel(modelId: value, resumed: result.resumed, record: updated, format: flags.format)
        case .configOption:
            // acpx prints the user's original key, not the resolved config id.
            printSetConfig(
                key: key, value: value, configOptions: result.configOptions ?? [], resumed: result.resumed,
                record: updated, format: flags.format)
        }
        return ExitCodes.success
    }

    private static func printSetConfig(
        key: String, value: String, configOptions: [JSONValue], resumed: Bool, record: SessionRecord,
        format: String
    ) {
        switch format {
        case "json":
            Console.out(jsonObject([
                ("action", .string("config_set")),
                ("configId", .string(key)),
                ("value", .string(value)),
                ("resumed", .bool(resumed)),
                ("configOptions", .array(configOptions)),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId)),
                ("agentSessionId", record.agentSessionId.map(JSONValue.string))
            ]).compact() + "\n")
        case "quiet":
            Console.out("\(value)\n")
        default:
            Console.out("config set: \(key)=\(value) (\(configOptions.count) options)\n")
        }
    }

    private static func printSetModel(modelId: String, resumed: Bool, record: SessionRecord, format: String) {
        switch format {
        case "json":
            Console.out(jsonObject([
                ("action", .string("model_set")),
                ("modelId", .string(modelId)),
                ("resumed", .bool(resumed)),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId)),
                ("agentSessionId", record.agentSessionId.map(JSONValue.string))
            ]).compact() + "\n")
        case "quiet":
            Console.out("\(modelId)\n")
        default:
            Console.out("model set: \(modelId)\n")
        }
    }

    // MARK: set routing (ported from acpx handleSetConfigOption / handleSetModel)

    enum SetOperation: Equatable {
        case model
        case configOption(String)
    }

    /// Decide whether `set <key> <value>` is a model selection or a config option. acpx's
    /// `handleSetConfigOption` hands the `model` key to `handleSetModel` whatever the
    /// agent is: `setSessionModel` then uses the control the session advertises — its
    /// model config option (claude) or `session/set_model` (codex) — and refuses when it
    /// advertises neither. Other keys pass through `resolveCompatibleConfigId`.
    static func resolveSetOperation(key: String, agentCommand: String) -> SetOperation {
        if key == "model" { return .model }
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
