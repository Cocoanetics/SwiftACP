import ACPXCore
import Foundation
import SwiftACP

/// `acpx [<agent>] [prompt...]` / `acpx [<agent>] prompt [prompt...]` — prompt a
/// persistent session (routed by cwd, walking up to the git root).
///
/// The turn always runs through the `acpxd` daemon — the single manager that holds
/// the live agent session and owns its persisted history. The CLI is a pure client:
/// it streams the daemon's `session/update`s to the renderer and never writes the
/// session record itself. There is no direct (no-daemon) fallback: routing every
/// turn through one manager is what stops concurrent `acpx`/MCP accesses from
/// colliding on a session or clobbering its history.
enum PromptCommand {
    static func run(_ context: CommandContext) throws -> Int32 {
        let scan = context.options
        let flags = try context.globalFlags()
        let permissionRules = try flags.permissionRules()
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.parsed("session", parseSessionName)
        let promptBlocks = try PromptInputResolver.resolve(
            words: context.positionals, file: scan.string("file"), cwd: flags.cwd)
        // Absent `--no-wait`, a turn for a session that's already running one queues
        // behind it (the daemon serializes turns per session); `--no-wait` makes the
        // daemon reject the turn immediately instead of waiting.
        let wait = !scan.flag("no-wait")

        // `--mcp-config` re-attaches the named servers to the routed session before
        // the turn: a running daemon reconnects the session so they take effect,
        // which keeps the session (and its history) rather than making the caller
        // close and recreate it.
        let record = try SessionLifecycle.applyExplicitMcpServers(
            to: try findRoutedSessionOrThrow(agent: agent, name: name), config: context.config)
        printSessionBanner(record, cwd: agent.cwd, flags: flags)
        // Checked here, as acpx checks it building its client; the daemon applies it to
        // this turn.
        let terminalOutputCeiling = try TerminalOutputLimit.ceiling()

        // JSON mode prints the turn's exchange as it crosses the wire, as acpx does.
        var options = renderOptions(flags)
        options.streamsWire = true
        let renderer = OutputRenderer(options: options)
        let sessionId = record.acpSessionId

        // The acpxd daemon owns turn persistence: by the time `runPrompt` returns it
        // has written the prompt, streamed updates, token usage, and event log to the
        // session record (via TurnPersister, which also stamps the activity
        // timestamps). So the CLI streams output and exits — it must not write the
        // record here, or its stale pre-turn snapshot would clobber the turn the
        // daemon just persisted. There is no direct fallback: if the daemon can't be
        // reached the turn fails loudly rather than running outside the manager.
        let permissionMode = try Flags.resolvePermissionMode(flags, default: context.config.defaultPermissions)
        let turn: DaemonTurn = try runBlocking {
            do {
                return try await DaemonClient.runPrompt(
                    sessionId: sessionId, content: try PromptInputResolver.jsonValues(promptBlocks), wait: wait,
                    permissionMode: permissionMode, nonInteractivePermissions: flags.nonInteractivePermissions,
                    permissionPolicy: permissionRules, terminalOutputCeiling: terminalOutputCeiling,
                    model: flags.model, renderer: renderer)
            } catch let unavailable as DaemonUnavailable {
                throw CLIError(unavailable.cliMessage)
            } catch let failed as DaemonTurnFailed {
                renderer.turnFailed(failed.event)
                throw FailureAlreadyShown(underlying: failed.underlying, outputCode: failed.event.outputCode)
            } catch {
                throw turnFailure(error, renderer: renderer)
            }
        }
        renderer.finish(stopReason: turn.stopReason)
        renderer.promptMetadata(usage: turn.usage.map(WireJSON.init), cost: turn.cost.map(WireJSON.init))
        let permissions = turn.permissions ?? PermissionStats()
        if permissions.promptUnavailable { renderer.permissionPromptUnavailable(sessionId: record.acpxRecordId) }
        return permissionExitCode(
            permissions, quiet: flags.format == "quiet", queueDetail: "QUEUE_RUNTIME_PROMPT_FAILED")
    }

    /// How a failed turn reaches the top level. When the JSON stream already shows how
    /// it failed — the agent's error response — nothing more is printed for it, as in
    /// acpx (`outputAlreadyEmitted`).
    static func turnFailure(_ error: Error, renderer: OutputRenderer) -> Error {
        guard renderer.streamsWireJSON, renderer.showedFailure(error.localizedDescription) else { return error }
        return FailureAlreadyShown(underlying: error)
    }

    // MARK: - Routing + banner

    static func findRoutedSessionOrThrow(agent: AgentInvocation, name: String?) throws -> SessionRecord {
        let gitRoot = SessionStore.findGitRepositoryRoot(agent.cwd)
        let walkBoundary = gitRoot ?? agent.cwd
        if let record = SessionStore.findSessionByDirectoryWalk(
            agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, boundary: walkBoundary) {
            return record
        }
        let createCmd =
            name.map { "acpx \(agent.agentName) sessions new --name \($0)" }
            ?? "acpx \(agent.agentName) sessions new"
        throw NoSessionError(
            "⚠ No acpx session found (searched up to \(walkBoundary)).\nCreate one: \(createCmd)")
    }

    static func printSessionBanner(_ record: SessionRecord, cwd: String, flags: GlobalFlags) {
        if flags.format == "quiet" || (flags.jsonStrict && flags.format == "json") { return }
        let label = record.name ?? "cwd"
        let sessionCwd = ACPXPaths.resolve(record.cwd, base: "/")
        // The banner prints before the daemon is contacted, so it doesn't know
        // whether acpxd still holds this agent live — report the conservative
        // "needs reconnect" (matching upstream acpx, whose CLI process never has
        // a live agent at this point either) rather than paying a daemon
        // round-trip just for the banner.
        let status = "needs reconnect"
        if sessionCwd == cwd {
            Console.errLine(
                "[acpx] session \(label) (\(record.acpxRecordId)) · \(sessionCwd) · agent \(status)")
        } else {
            let routedFrom = routedFromPath(sessionCwd: sessionCwd, currentCwd: cwd)
            Console.errLine(
                "[acpx] session \(label) (\(record.acpxRecordId)) · \(sessionCwd) "
                    + "(routed from \(routedFrom)) · agent \(status)")
        }
    }

    private static func routedFromPath(sessionCwd: String, currentCwd: String) -> String {
        let rel = relative(from: sessionCwd, to: currentCwd)
        if rel.isEmpty || rel == "." { return "." }
        return rel.hasPrefix(".") ? rel : "./" + rel
    }

    private static func relative(from base: String, to target: String) -> String {
        let baseParts = base.split(separator: "/").map(String.init)
        let targetParts = target.split(separator: "/").map(String.init)
        var i = 0
        while i < baseParts.count, i < targetParts.count, baseParts[i] == targetParts[i] { i += 1 }
        let ups = Array(repeating: "..", count: baseParts.count - i)
        return (ups + targetParts[i...]).joined(separator: "/")
    }
}
