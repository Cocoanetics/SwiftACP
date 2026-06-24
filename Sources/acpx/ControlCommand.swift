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
        // Without a live daemon holding an in-flight prompt, there is nothing to cancel.
        printCancel(sessionId: record?.acpxRecordId ?? "", cancelled: false, format: flags.format)
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
        var record = try PromptCommand.findRoutedSessionOrThrow(agent: agent, name: name)
        let permission = try SessionLifecycle.permissionPolicy(flags, config: context.config)
        let meta = SessionLifecycle.claudeMeta(agent: agent, flags: flags)
        let sessionId = record.acpSessionId
        let cwd = agent.cwd
        let agentCommand = agent.agentCommand

        try runBlocking {
            let handle = try await ACPAgent.launch(
                agent: agentCommand, cwd: cwd, permission: permission,
                authCredentials: context.config.auth, authPolicy: flags.authPolicy,
                inheritStderr: flags.verbose)
            do {
                let session = try await reconnectOrFresh(handle, sessionId: sessionId, cwd: cwd, meta: meta)
                try await session.setMode(modeId)
                await handle.close()
            } catch {
                await handle.close()
                throw CLIError(error.localizedDescription)
            }
        }
        // Persist desired mode.
        var acpx = record.acpx ?? SessionAcpxState()
        acpx.desiredModeId = modeId
        acpx.currentModeId = modeId
        record.acpx = acpx
        record.lastUsedAt = nowISO()
        try? SessionStore.writeRecord(record)

        printSetMode(modeId: modeId, record: record, format: flags.format)
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
        let permission = try SessionLifecycle.permissionPolicy(flags, config: context.config)
        let meta = SessionLifecycle.claudeMeta(agent: agent, flags: flags)
        let sessionId = record.acpSessionId
        let cwd = agent.cwd
        let agentCommand = agent.agentCommand

        // The set_config_option response carries the agent's updated config options;
        // acpx reports their count and echoes them in the JSON envelope.
        let resultOptions: [JSONValue] = try runBlocking {
            let handle = try await ACPAgent.launch(
                agent: agentCommand, cwd: cwd, permission: permission,
                authCredentials: context.config.auth, authPolicy: flags.authPolicy,
                inheritStderr: flags.verbose)
            do {
                let session = try await reconnectOrFresh(handle, sessionId: sessionId, cwd: cwd, meta: meta)
                let options: [JSONValue]
                switch operation {
                case .model:
                    try await handle.connection.setModel(
                        SetSessionModelRequest(sessionId: session.id, modelId: value))
                    options = []
                case .configOption(let configId):
                    let response = try await handle.connection.setConfigOption(
                        SetSessionConfigOptionRequest(sessionId: session.id, configId: configId, value: value))
                    options = response.configOptions ?? []
                }
                await handle.close()
                return options
            } catch {
                await handle.close()
                throw CLIError(error.localizedDescription)
            }
        }

        var updated = record
        var acpx = updated.acpx ?? SessionAcpxState()
        switch operation {
        case .model:
            acpx.currentModelId = value
        case .configOption(let configId):
            var desired = acpx.desiredConfigOptions ?? [:]
            desired[configId] = value
            acpx.desiredConfigOptions = desired
        }
        updated.acpx = acpx
        updated.lastUsedAt = nowISO()
        try? SessionStore.writeRecord(updated)

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
    /// advertised options, which the CLI's ephemeral reconnect-then-fresh path
    /// doesn't carry. acpx itself sends the key verbatim there, so `set thinking`
    /// fails identically in both (the agent rejects the unknown option).
    private static func resolveCompatibleConfigId(agentCommand: String, configId: String) -> String {
        if isLegacyZedCodexAcpInvocation(agentCommand), configId == "thought_level" {
            return "reasoning_effort"
        }
        return configId
    }

    private static func isLegacyZedCodexAcpInvocation(_ agentCommand: String) -> Bool {
        agentCommand.range(of: #"@zed-industries/codex-acp\b"#, options: .regularExpression) != nil
    }

    // MARK: shared

    /// Reconnect to a session (resume/load), falling back to a fresh session.
    static func reconnectOrFresh(
        _ handle: ACPAgent, sessionId: String, cwd: String, meta: JSONValue?
    ) async throws -> ACPSession {
        do {
            return try await handle.reconnectSession(id: sessionId, cwd: cwd, meta: meta)
        } catch {
            let response = try await handle.connection.newSession(
                NewSessionRequest(cwd: cwd, mcpServers: [], meta: meta))
            return ACPSession(id: response.sessionId, agent: handle, modes: response.modes)
        }
    }
}
