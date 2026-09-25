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
        let permissionRules = try flags.permissionRules()

        let configOptions = try scan.parsedAll("config-option", parseSessionConfigOptionAssignment)
        let prompt = try PromptInputResolver.contentBlocks(
            PromptInputResolver.resolve(words: context.positionals, file: scan.string("file"), cwd: flags.cwd))
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let permission = try SessionLifecycle.permissionPolicy(flags, config: context.config)
        let mcpServers = try context.config.mcpServerSpecs()
        let meta = SessionLifecycle.sessionMeta(agent: agent, flags: flags)
        var options = renderOptions(flags)
        options.streamsWire = true
        let renderer = OutputRenderer(options: options)
        let onClientRequest = clientOperationObserver(renderer)
        // JSON mode prints the exchange from the handshake on, so the tap goes in at launch.
        // Quiet mode reads the prompt response's usage and cost off the wire, as acpx does.
        let promptResult = PromptResultCapture()
        let onRawWire: RawWireTap.Observer = { direction, body in
            promptResult.observe(direction, body)
            if renderer.streamsWireJSON { renderer.acpMessage(direction, body) }
        }
        let auth = context.config.auth
        // acpx's `withInterrupt`: a signal puts the run down as its `handleInterrupt` does,
        // and unless the run ended first, the CLI exits `INTERRUPTED` without a word.
        let interrupt = RunInterrupt()

        return try runBlocking {
            do {
                return try await Interrupts.withInterrupt({
                    let handle: ACPAgent
                    do {
                        handle = try await interrupt.launch {
                            try await launchAgent(within: flags.timeoutMs) {
                                try await ACPAgent.launch(
                                    agent: agent.agentCommand, argv: agent.agentArgv, cwd: agent.cwd,
                                    permission: permission, nonInteractivePermissions: flags.nonInteractivePolicy,
                                    permissionRules: permissionRules, capabilities: flags.clientCapabilities,
                                    authCredentials: auth, authPolicy: flags.authPolicy, inheritStderr: flags.verbose,
                                    onClientRequest: onClientRequest, onRawWire: onRawWire)
                            }
                        }
                    } catch {
                        return reportFailure(error, renderer: renderer, format: flags.format)
                    }
                    return await run(
                        prompt, on: handle, agent: agent, mcpServers: mcpServers, meta: meta,
                        configOptions: configOptions, flags: flags, renderer: renderer, promptResult: promptResult,
                        interrupt: interrupt)
                }, onInterrupt: { await interrupt.putDown(endInterrupted: $0) })
            } catch is InterruptedError {
                renderer.flushText()
                renderer.flushQuietText()
                return ExitCodes.interrupted
            }
        }
    }

    /// The run once its agent is up: a session with the invocation's model and options,
    /// then the prompt — each within `--timeout` — reported as acpx reports it.
    private static func run(
        _ prompt: [ContentBlock], on handle: ACPAgent, agent: AgentInvocation, mcpServers: [MCPServerSpec],
        meta: JSONValue?, configOptions: [ModelApplication.ConfigOptionAssignment], flags: GlobalFlags,
        renderer: OutputRenderer, promptResult: PromptResultCapture, interrupt: RunInterrupt
    ) async -> Int32 {
        // Whether the prompt may go again depends on what the connection had of the
        // agent meanwhile.
        let sideEffects = PromptSideEffects()
        await handle.connection.setWireMessageObserver { sideEffects.observe($0, $1) }
        let session: ACPSession
        do {
            session = try await openSession(
                on: handle, agent: agent, mcpServers: mcpServers, meta: meta, model: flags.model,
                configOptions: configOptions, timeoutMs: flags.timeoutMs, quiet: quietOutput(flags))
        } catch {
            await handle.close()
            return reportFailure(error, renderer: renderer, format: flags.format)
        }
        interrupt.opened(session.id)
        let run: PromptRun
        do {
            run = try await runPrompt(
                prompt, on: session, policy: PromptPolicy(flags), renderer: renderer, sideEffects: sideEffects)
        } catch {
            await handle.close()
            // An agent gone with the prompt out is reported too, once, in any format: acpx
            // 0.19.3 marks its error shown only when the output shows the agent's error
            // (`markOutputAlreadyEmitted`, #778).
            return reportFailure(
                error, renderer: renderer, format: flags.format, agentErrorShown: showsAgentError(error))
        }
        renderer.finish(stopReason: run.response.stopReason)
        renderer.promptMetadata(usage: promptResult.result?["usage"], cost: promptResult.result?["cost"])
        await handle.close()
        if run.permissions.promptUnavailable, flags.format != "quiet",
            !renderer.showedFailure(FileSystemPermissionError.promptUnavailable.description) {
            // acpx rethrows this after the turn; its top-level handler reports it
            // unless the stream already shows the client's refusal saying the same.
            return reportFailure(PromptUnavailable(), renderer: renderer, format: flags.format)
        }
        return permissionExitCode(run.permissions, quiet: flags.format == "quiet")
    }

    /// The run's session, as acpx's `runOnce` opens it: `session/new` with the
    /// invocation's session options (`meta`), then its model and config options — each
    /// within `timeoutMs`. A warning about them goes to stderr, unless `quiet`.
    static func openSession(
        on handle: ACPAgent, agent: AgentInvocation, mcpServers: [MCPServerSpec], meta: JSONValue?,
        model: String?, configOptions: [ModelApplication.ConfigOptionAssignment], timeoutMs: Int?, quiet: Bool
    ) async throws -> ACPSession {
        let connection = handle.connection
        let request = NewSessionRequest(cwd: agent.cwd, mcpServers: mcpServers, meta: meta)
        let response = try await withTimeout(milliseconds: timeoutMs) {
            try await connection.newSession(request)
        }
        try await ModelApplication.applySessionControls(
            connection: connection, session: response, model: model, configOptions: configOptions,
            agentCommand: agent.agentCommand, timeoutMilliseconds: timeoutMs,
            onWarning: quiet ? nil : { Console.errLine("[acpx] warning: \($0)") })
        return ACPSession(id: response.sessionId, agent: handle, modes: response.modes)
    }

    /// Launch the agent within `--timeout`, as acpx starts its client. At the deadline
    /// the launch is cancelled, and waited for: it puts down the agent it started on its
    /// way out, as acpx closes the client it was starting. One that came up just then is
    /// closed.
    static func launchAgent(
        within milliseconds: Int?, _ launch: @escaping @Sendable () async throws -> ACPAgent
    ) async throws -> ACPAgent {
        try await withTimeout(milliseconds: milliseconds, launch) { await $0.close() }
    }

    /// Report a failed run the way acpx does in `format`, returning its exit code.
    ///
    /// - json: nothing more when the stream already shows the failure (the agent's
    ///   error response, or the client's refusal it repeats), else one JSON-RPC error
    ///   line; never anything on stderr.
    /// - `agentErrorShown`: the failure came with the agent's error response, which the
    ///   output shows — acpx's `markOutputAlreadyEmitted`.
    /// - quiet: acpx's quiet formatter — what the agent said so far, then one stderr
    ///   line: the code qualified by any detail code, the agent's `data.details` in place
    ///   of the message when given.
    /// - text: the agent's error response is rendered where acpx's formatter renders
    ///   it, as `[error] RUNTIME: <details or message>` with hints going by that text,
    ///   and not repeated (`agentErrorShown`: it already is); anything else goes to
    ///   stderr bare, with its hints, as acpx's top-level handler prints it.
    static func reportFailure(
        _ error: Error, renderer: OutputRenderer, format: String, agentErrorShown: Bool = false,
        err: (String) -> Void = { Console.errLine($0) }
    ) -> Int32 {
        let failure = RunFailure(error)
        renderer.flushText()
        switch format {
        case "json":
            if !agentErrorShown, !renderer.showedFailure(failure.message) {
                renderer.jsonFailure(
                    outputCode: failure.outputCode, detailCode: failure.detailCode, origin: failure.origin,
                    message: failure.message)
            }
        case "quiet":
            renderer.flushQuietText()
            let qualifier = failure.detailCode.map { "\(failure.outputCode) \($0)" } ?? failure.outputCode
            let text = (failure.acpDetails ?? failure.message)
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            err("[acpx] error: \(qualifier) \(text)")
        default:
            if agentErrorShown {
                break
            } else if error is JSONRPCErrorBody {
                showAgentError(failure, renderer: renderer)
            } else {
                err(failure.message)
                for hint in remediationHints(
                    code: failure.outputCode, origin: failure.origin, detailCode: failure.detailCode,
                    message: failure.message, acp: TurnFailure.payload(of: error)) {
                    err(hint)
                }
            }
        }
        return exitCode(forOutputCode: failure.outputCode)
    }

    /// The agent's error response, where acpx's text formatter shows it:
    /// `[error] RUNTIME: <details or message>`, hints going by that text.
    static func showAgentError(_ failure: RunFailure, renderer: OutputRenderer) {
        renderer.renderError(code: "RUNTIME", failure.acpDetails ?? failure.message)
    }

    /// ``reportFailure(_:renderer:format:agentErrorShown:err:)`` in JSON mode.
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
            message = TurnFailure.message(of: error)
            switch error {
            case let rpc as JSONRPCErrorBody:
                message = rpc.message
                if case .object(let fields)? = rpc.data, case .string(let details)? = fields["details"] {
                    let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
                    acpDetails = trimmed.isEmpty ? nil : trimmed
                }
                // `resolveDetailCode`: the agent's error saying it needs credentials.
                if TurnFailure.payload(of: rpc)?.saysAuthRequired == true { detailCode = "AUTH_REQUIRED" }
            case let meta as OutputErrorMeta:
                outputCode = meta.outputCode ?? outputCode
                detailCode = meta.detailCode
                origin = meta.origin ?? origin
            case let unsupported as ModelApplication.UnsupportedError:
                message = unsupported.message
            case let unavailable as PromptUnavailable:
                outputCode = "PERMISSION_PROMPT_UNAVAILABLE"
                message = FileSystemPermissionError.promptUnavailable.description
                acpDetails = unavailable.agentError.flatMap { RunFailure($0).acpDetails }
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
    struct PromptUnavailable: Error {
        /// The agent's error answering the prompt this failure stands in for — acpx
        /// reports it with that error's details.
        var agentError: JSONRPCErrorBody?
    }

    /// Whether `error`, thrown by ``runPrompt(_:on:policy:renderer:sideEffects:)``, came
    /// with the agent's error response, which the output shows already.
    static func showsAgentError(_ error: Error) -> Bool {
        error is JSONRPCErrorBody || (error as? PromptUnavailable)?.agentError != nil
    }

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
    static func quietOutput(_ flags: GlobalFlags) -> Bool {
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
