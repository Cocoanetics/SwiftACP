import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `acpx [<agent>] [prompt...]` / `acpx [<agent>] prompt [prompt...]` — prompt a
/// persistent session (routed by cwd, walking up to the git root).
///
/// Note: this currently spawns the agent per invocation and reconnects via
/// `session/load`. Session reuse across invocations is provided by the `acpxd`
/// MCP daemon (added separately); output is identical either way.
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

        let record = try findRoutedSessionOrThrow(agent: agent, name: name)
        printSessionBanner(record, cwd: agent.cwd, flags: flags)

        let permission = try SessionLifecycle.permissionPolicy(flags, config: context.config)
        let meta = SessionLifecycle.claudeMeta(agent: agent, flags: flags)
        let renderer = OutputRenderer(options: renderOptions(flags))
        let sessionId = record.acpSessionId
        let cwd = agent.cwd
        let agentCommand = agent.agentCommand

        let result: (stopReason: StopReason, loadError: String?) = try runBlocking {
            // Prefer the daemon (session reuse via MCP); fall back to a direct
            // spawn if it can't be reached. Output is identical either way.
            do {
                let stop = try await DaemonClient.runPrompt(
                    sessionId: sessionId, text: promptText, renderer: renderer)
                return (stop, nil)
            } catch is DaemonUnavailable {
                return try await directPrompt(
                    agentCommand: agentCommand, cwd: cwd, sessionId: sessionId, meta: meta,
                    permission: permission, authCredentials: context.config.auth,
                    authPolicy: flags.authPolicy, verbose: flags.verbose, promptText: promptText,
                    renderer: renderer)
            }
        }
        renderer.finish(stopReason: result.stopReason)
        if flags.verbose, let loadError = result.loadError {
            Console.errLine("[acpx] session reconnect failed, started fresh session: \(loadError)")
        }
        let stopReason = result.stopReason

        // Touch the session's activity timestamps.
        var updated = record
        updated.lastUsedAt = nowISO()
        updated.lastPromptAt = nowISO()
        try? SessionStore.writeRecord(updated)

        return stopReason == .refusal ? ExitCodes.error : ExitCodes.success
    }

    /// Direct (no-daemon) prompt: spawn the adapter, reconnect (or fresh), stream.
    static func directPrompt(
        agentCommand: String, cwd: String, sessionId: String, meta: JSONValue?,
        permission: PermissionPolicy, authCredentials: [String: String], authPolicy: String,
        verbose: Bool, promptText: String, renderer: OutputRenderer
    ) async throws -> (StopReason, String?) {
        let handle = try await ACPAgent.launch(
            agent: agentCommand, cwd: cwd, permission: permission,
            authCredentials: authCredentials, authPolicy: authPolicy, inheritStderr: verbose,
            onClientRequest: clientOperationObserver(renderer))
        do {
            var loadError: String?
            let session: ACPSession
            do {
                session = try await handle.reconnectSession(id: sessionId, cwd: cwd, meta: meta)
            } catch {
                let response = try await handle.connection.newSession(
                    NewSessionRequest(cwd: cwd, mcpServers: [], meta: meta))
                session = ACPSession(id: response.sessionId, agent: handle, modes: response.modes)
                loadError = error.localizedDescription
            }
            let outcome = try await session.run(promptText) { renderer.render($0) }
            await handle.close()
            return (outcome.stopReason, loadError)
        } catch let error as JSONRPCErrorBody {
            let cliError = turnFailure(error, renderer: renderer)
            await handle.close()
            throw cliError
        } catch {
            await handle.close()
            throw CLIError(error.localizedDescription)
        }
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
