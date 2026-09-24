import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `acpx [<agent>] exec [prompt...]` — a one-shot prompt with no saved session.
enum ExecCommand {
    static func run(_ context: CommandContext) throws -> Int32 {
        let scan = context.options
        let flags = try context.globalFlags()

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
                    agent: agent.agentCommand, argv: agent.agentArgv, cwd: agent.cwd, permission: permission,
                    nonInteractivePermissions: flags.nonInteractivePolicy,
                    capabilities: flags.clientCapabilities,
                    authCredentials: context.config.auth, authPolicy: flags.authPolicy,
                    inheritStderr: flags.verbose, onClientRequest: onClientRequest, onRawWire: onRawWire)
            } catch {
                return reportFailure(error, renderer: renderer, format: flags.format)
            }
            do {
                let response = try await handle.connection.newSession(
                    NewSessionRequest(cwd: agent.cwd, mcpServers: mcpServers, meta: meta))
                try await ModelApplication.applySessionControls(
                    connection: handle.connection, session: response, model: flags.model,
                    configOptions: configOptions, agentCommand: agent.agentCommand,
                    onWarning: quietOutput(flags) ? nil : { Console.errLine("[acpx] warning: \($0)") })
                let session = ACPSession(id: response.sessionId, agent: handle, modes: response.modes)
                renderer.promptAttemptStarts()
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
                await handle.close()
                return reportFailure(error, renderer: renderer, format: flags.format)
            }
        }
    }

    /// Report a failed run the way acpx does in `format`, returning its exit code.
    ///
    /// - json: nothing more when the stream already shows the failure (the agent's
    ///   error response, or the client's refusal it repeats), else one JSON-RPC error
    ///   line; never anything on stderr.
    /// - quiet: acpx's quiet formatter — one stderr line, the code qualified by any
    ///   detail code, the agent's `data.details` in place of the message when given.
    /// - text: the agent's error response is rendered where acpx's formatter renders
    ///   it, as `[error] RUNTIME: <details or message>` with hints going by that text,
    ///   and not repeated; anything else goes to stderr bare, with its hints, as acpx's
    ///   top-level handler prints it.
    static func reportFailure(
        _ error: Error, renderer: OutputRenderer, format: String,
        err: (String) -> Void = { Console.errLine($0) }
    ) -> Int32 {
        let failure = RunFailure(error)
        switch format {
        case "json":
            if !renderer.showedFailure(failure.message) {
                renderer.jsonFailure(
                    outputCode: failure.outputCode, detailCode: failure.detailCode, origin: failure.origin,
                    message: failure.message)
            }
        case "quiet":
            let qualifier = failure.detailCode.map { "\(failure.outputCode) \($0)" } ?? failure.outputCode
            let text = (failure.acpDetails ?? failure.message)
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            err("[acpx] error: \(qualifier) \(text)")
        default:
            if error is JSONRPCErrorBody {
                renderer.renderError(code: "RUNTIME", failure.acpDetails ?? failure.message)
            } else {
                err(failure.message)
                for hint in remediationHints(
                    code: failure.outputCode, origin: failure.origin, detailCode: failure.detailCode,
                    message: failure.message, acpCode: nil) {
                    err(hint)
                }
            }
        }
        return exitCode(forOutputCode: failure.outputCode)
    }

    /// ``reportFailure(_:renderer:format:)`` in JSON mode.
    static func reportJSONFailure(_ error: Error, renderer: OutputRenderer) -> Int32 {
        reportFailure(error, renderer: renderer, format: "json")
    }

    /// A failed run as acpx's top-level `normalizeOutputError` sees it.
    struct RunFailure {
        var outputCode = "RUNTIME"
        var detailCode: String?
        var origin = "cli"
        var message: String
        /// The agent's `data.details`, when the failure is its error response and it
        /// gave some (acpx's `preferredAcpErrorDetails`).
        var acpDetails: String?

        init(_ error: Error) {
            message = error.localizedDescription
            switch error {
            case let rpc as JSONRPCErrorBody:
                message = rpc.message
                if case .object(let fields)? = rpc.data, case .string(let details)? = fields["details"] {
                    let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
                    acpDetails = trimmed.isEmpty ? nil : trimmed
                }
            case let meta as OutputErrorMeta:
                outputCode = meta.outputCode ?? outputCode
                detailCode = meta.detailCode
                origin = meta.origin ?? origin
            case let unsupported as ModelApplication.UnsupportedError:
                message = unsupported.message
            case is PromptUnavailable:
                outputCode = "PERMISSION_PROMPT_UNAVAILABLE"
                message = FileSystemPermissionError.promptUnavailable.description
            default:
                break
            }
            // `resolveOutputErrorCode`: a runtime failure saying the session is gone.
            if outputCode == "RUNTIME", ReconnectFallback.isResourceNotFound(error) {
                outputCode = "NO_SESSION"
            }
        }
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
