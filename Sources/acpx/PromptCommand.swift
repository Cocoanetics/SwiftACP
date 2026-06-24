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
        let scan = try context.scan([
            OptionSpec("session", short: "s", takesValue: true),
            OptionSpec("file", short: "f", takesValue: true),
            OptionSpec("wait", negatable: true)
        ])
        let flags = try context.globalFlags(scan)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.string("session").map(parseSessionName)
        let promptText = try PromptInputResolver.resolve(
            words: context.positionals, file: scan.string("file"), cwd: flags.cwd)
        // Absent `--no-wait`, a turn for a session that's already running one queues
        // behind it (the daemon serializes turns per session); `--no-wait` makes the
        // daemon reject the turn immediately instead of waiting.
        let wait = scan.boolean("wait") ?? true

        let record = try findRoutedSessionOrThrow(agent: agent, name: name)
        printSessionBanner(record, cwd: agent.cwd, flags: flags)

        let renderer = OutputRenderer(options: renderOptions(flags))
        let sessionId = record.acpSessionId

        // The acpxd daemon owns turn persistence: by the time `runPrompt` returns it
        // has written the prompt, streamed updates, token usage, and event log to the
        // session record (via TurnPersister, which also stamps the activity
        // timestamps). So the CLI streams output and exits — it must not write the
        // record here, or its stale pre-turn snapshot would clobber the turn the
        // daemon just persisted. There is no direct fallback: if the daemon can't be
        // reached the turn fails loudly rather than running outside the manager.
        let stopReason: StopReason = try runBlocking {
            do {
                return try await DaemonClient.runPrompt(
                    sessionId: sessionId, text: promptText, wait: wait, renderer: renderer)
            } catch let unavailable as DaemonUnavailable {
                throw CLIError(unavailable.cliMessage)
            }
        }
        renderer.finish(stopReason: stopReason)
        return stopReason == .refusal ? ExitCodes.error : ExitCodes.success
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
        // (No live daemon yet, so the agent always reports "needs reconnect".)
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
