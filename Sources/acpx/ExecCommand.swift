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

        if context.config.disableExec { return refuseDisabledExec(flags) }

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
        var options = renderOptions(flags)
        options.streamsWire = true
        let renderer = OutputRenderer(options: options)
        let onClientRequest = clientOperationObserver(renderer)
        // JSON mode prints the exchange from the handshake on, so the tap goes in at launch.
        let onRawWire: RawWireTap.Observer?
        if renderer.streamsWireJSON {
            onRawWire = { direction, body in renderer.acpMessage(direction, body) }
        } else {
            onRawWire = nil
        }

        return try runBlocking {
            let handle: ACPAgent
            do {
                handle = try await ACPAgent.launch(
                    agent: agent.agentCommand, cwd: agent.cwd, permission: permission,
                    nonInteractivePermissions: flags.nonInteractivePolicy,
                    capabilities: flags.clientCapabilities,
                    authCredentials: context.config.auth, authPolicy: flags.authPolicy,
                    inheritStderr: flags.verbose, onClientRequest: onClientRequest, onRawWire: onRawWire)
            } catch where renderer.streamsWireJSON {
                return reportJSONFailure(error, renderer: renderer)
            }
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
                if renderer.streamsWireJSON, permissions.promptUnavailable {
                    // acpx rethrows this after the turn; its top-level handler reports it
                    // unless the stream already shows the client's refusal saying the same.
                    return reportJSONFailure(PromptUnavailable(), renderer: renderer)
                }
                return permissionExitCode(permissions, quiet: flags.format == "quiet")
            } catch {
                let failure = renderer.streamsWireJSON ? nil : textFailure(error, renderer: renderer)
                await handle.close()
                if let failure { throw failure }
                return reportJSONFailure(error, renderer: renderer)
            }
        }
    }

    /// How text and quiet modes report a failed run (their exact acpx wording is #60).
    private static func textFailure(_ error: Error, renderer: OutputRenderer) -> Error {
        switch error {
        case let rpc as JSONRPCErrorBody: return turnFailure(rpc, renderer: renderer)
        case let unsupported as ModelApplication.UnsupportedError: return CLIError(unsupported.message)
        default: return CLIError(error.localizedDescription)
        }
    }

    /// A failure in JSON mode, as acpx's top-level handler reports it: nothing more
    /// when the stream already shows it — the agent's error response, or the client's
    /// refusal it repeats — else one JSON-RPC error line; never anything on stderr.
    /// Returns the exit code for the failure's output code.
    static func reportJSONFailure(_ error: Error, renderer: OutputRenderer) -> Int32 {
        let outputCode: String
        let detailCode: String?
        let message: String
        switch error {
        case let rpc as JSONRPCErrorBody:
            (outputCode, detailCode, message) = ("RUNTIME", nil, rpc.message)
        case let launch as AgentLaunchError:
            (outputCode, detailCode, message) = ("RUNTIME", launch.detailCode, launch.localizedDescription)
        case let unsupported as ModelApplication.UnsupportedError:
            (outputCode, detailCode, message) = ("RUNTIME", nil, unsupported.message)
        case is PromptUnavailable:
            (outputCode, detailCode, message) = (
                "PERMISSION_PROMPT_UNAVAILABLE", nil, FileSystemPermissionError.promptUnavailable.description
            )
        default:
            (outputCode, detailCode, message) = ("RUNTIME", nil, error.localizedDescription)
        }
        if !renderer.showedFailure(message) {
            renderer.jsonFailure(outputCode: outputCode, detailCode: detailCode, message: message)
        }
        return exitCode(forOutputCode: outputCode)
    }

    /// A write needed a confirmation nobody could give (`--non-interactive-permissions fail`).
    struct PromptUnavailable: Error {}

    /// acpx refuses `exec` under `disableExec` the way it reports any failure, in the
    /// chosen format: the JSON-RPC error line, the quiet `[acpx] error:` line, or the
    /// bare message.
    private static func refuseDisabledExec(_ flags: GlobalFlags) -> Int32 {
        let message = "exec subcommand is disabled by configuration (disableExec: true)"
        switch flags.format {
        case "json":
            Console.out(JSONErrorLine.make(
                outputCode: "EXEC_DISABLED", origin: "cli", message: message, sessionId: "unknown") + "\n")
        case "quiet":
            Console.errLine("[acpx] error: EXEC_DISABLED \(message)")
        default:
            Console.errLine(message)
        }
        return ExitCodes.error
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
