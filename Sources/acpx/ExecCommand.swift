import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `acpx [<agent>] exec [prompt...]` — a one-shot prompt with no saved session.
enum ExecCommand {
    static func run(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([
            OptionSpec("file", short: "f", takesValue: true, value: "path"),
            OptionSpec("config-option", takesValue: true, repeats: true, value: "key=value")
        ])
        let flags = try context.globalFlags(scan)

        if context.config.disableExec {
            if flags.format == "json" {
                Console.out(jsonObject([
                    ("jsonrpc", .string("2.0")),
                    ("error", jsonObject([
                        ("code", .integer(-32603)),
                        ("message", .string("exec subcommand is disabled by configuration (disableExec: true)")),
                        ("data", jsonObject([("acpxCode", .string("EXEC_DISABLED"))]))
                    ]))
                ]).compact() + "\n")
            } else {
                Console.errLine("Error: exec subcommand is disabled by configuration (disableExec: true)")
            }
            return ExitCodes.error
        }

        let configOptions = try scan.parsedAll("config-option", parseSessionConfigOptionAssignment)
        let prompt = try PromptBlock.contentBlocks(
            text: "",
            blocks: try PromptInputResolver.resolve(
                words: context.positionals, file: scan.string("file"), cwd: flags.cwd),
            requestLimit: nil)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let permission = try SessionLifecycle.permissionPolicy(flags, config: context.config)
        let mcpServers = try context.config.mcpServerSpecs()
        let meta = SessionLifecycle.sessionMeta(agent: agent, flags: flags)
        let renderer = OutputRenderer(options: renderOptions(flags))
        let onClientRequest = clientOperationObserver(renderer)

        return try runBlocking {
            let handle = try await ACPAgent.launch(
                agent: agent.agentCommand, cwd: agent.cwd, permission: permission,
                nonInteractivePermissions: flags.nonInteractivePolicy,
                capabilities: flags.clientCapabilities,
                authCredentials: context.config.auth, authPolicy: flags.authPolicy,
                inheritStderr: flags.verbose, onClientRequest: onClientRequest)
            do {
                let response = try await handle.connection.newSession(
                    NewSessionRequest(cwd: agent.cwd, mcpServers: mcpServers, meta: meta))
                try await ModelApplication.applySessionControls(
                    connection: handle.connection, session: response, model: flags.model,
                    configOptions: configOptions, agentCommand: agent.agentCommand,
                    onWarning: quietOutput(flags) ? nil : { Console.errLine("[acpx] warning: \($0)") })
                let session = ACPSession(id: response.sessionId, agent: handle, modes: response.modes)
                let outcome = try await session.run(
                    prompt, onUpdate: { renderer.render($0) },
                    onClientOperation: { renderer.clientOperation($0) },
                    onInboundRequest: { renderer.inboundRequest($0) })
                renderer.finish(stopReason: outcome.stopReason)
                let permissions = await handle.connection.permissionStats(for: response.sessionId)
                await handle.close()
                return permissionExitCode(permissions, quiet: flags.format == "quiet")
            } catch let error as JSONRPCErrorBody {
                let cliError = turnFailure(error, renderer: renderer)
                await handle.close()
                throw cliError
            } catch let error as ModelApplication.UnsupportedError {
                await handle.close()
                throw CLIError(error.message)
            } catch {
                await handle.close()
                throw CLIError(error.localizedDescription)
            }
        }
    }

    /// A finished turn exits 0 — whatever the stop reason, `refusal` included — unless
    /// it needed permission and was granted none: then `PERMISSION_DENIED` (5), even
    /// though the agent completed. acpx's `applyPermissionExitCode`; quiet mode also
    /// says why on stderr, since it prints nothing else.
    ///
    /// A write that needed an answer nobody could give (`--non-interactive-permissions
    /// fail`) fails the run outright: upstream rethrows it after the turn, so it wins
    /// over any approval, and quiet mode names it as `PERMISSION_PROMPT_UNAVAILABLE`.
    private static func permissionExitCode(_ stats: PermissionStats, quiet: Bool) -> Int32 {
        if stats.promptUnavailable {
            if quiet {
                Console.errLine(
                    "[acpx] error: PERMISSION_PROMPT_UNAVAILABLE "
                        + FileSystemPermissionError.promptUnavailable.description)
            }
            return ExitCodes.permissionDenied
        }
        guard stats.deniedEverything else { return ExitCodes.success }
        if quiet { Console.errLine("[acpx] error: PERMISSION_DENIED Permission request denied or cancelled") }
        return ExitCodes.permissionDenied
    }

    /// acpx suppresses adapter-level warnings under `--json-strict` and
    /// `--format quiet`, where stderr is part of the machine-readable contract.
    private static func quietOutput(_ flags: GlobalFlags) -> Bool {
        flags.jsonStrict || flags.format == "quiet"
    }
}

/// Handle a failed prompt turn the way acpx does on both streams: render
/// `[error] RUNTIME: <msg>` plus hint lines to the formatter (stdout), and
/// return a `CLIError` whose message carries the same hints for stderr (exit 1).
func turnFailure(_ error: JSONRPCErrorBody, renderer: OutputRenderer) -> CLIError {
    renderer.renderError(code: "RUNTIME", error.message, acpCode: error.code)
    // The CLI's stderr handler normalizes with a non-acp origin, so the
    // acp-protocol hint (origin-gated) is omitted here even when it shows on stdout.
    let hints = remediationHints(
        code: "RUNTIME", origin: nil, detailCode: nil, message: error.message, acpCode: error.code)
    return CLIError(([error.message] + hints).joined(separator: "\n"))
}

/// Builds the `[client]` progress observer: renders each outgoing agent request
/// method as `[client] <method> (running)`, except the prompt/cancel turn methods
/// (matching acpx, which excludes `session/prompt` and `session/cancel`).
func clientOperationObserver(_ renderer: OutputRenderer) -> @Sendable (String) -> Void {
    { method in
        if method != "session/prompt", method != "session/cancel" {
            renderer.clientOperation(method)
        }
    }
}

/// Maps the resolved string format to the renderer's `RenderOptions`.
func renderOptions(_ flags: GlobalFlags) -> RenderOptions {
    let format: OutputFormat
    switch flags.format {
    case "json": format = .json
    case "quiet": format = .quiet
    default: format = .text
    }
    return RenderOptions(format: format, suppressReads: flags.suppressReads)
}
