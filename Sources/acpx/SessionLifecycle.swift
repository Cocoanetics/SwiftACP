import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `sessions new` / `sessions ensure` — create (or reuse) a session by spawning
/// the agent directly via ACP (no daemon), matching acpx's `createSession`.
enum SessionLifecycle {
    static func new(_ context: CommandContext) throws -> Int32 {
        let scan = context.options
        let flags = try context.globalFlags()
        let permissions = try resolvePermissions(flags, config: context.config)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.parsed("name", parseSessionName)

        let replaced = SessionStore.findSession(
            agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, includeClosed: false)
        // The new session first, then the one it replaces closed, as acpx 0.19.3 has it
        // (#778, for our openclaw/acpx#767): a creation that fails leaves that one open.
        let record = try createSession(
            agent: agent, name: name, flags: flags, config: context.config, permissions: permissions)
        if let replaced {
            if record.acpxRecordId == replaced.acpxRecordId {
                // The agent gave the new session the replaced one's id: the record is the new
                // session's, and closing it would close that (openclaw/acpx#805; acpx 0.19.3
                // spares only a resume). A daemon holding the old one lets its agent go —
                // no `session/close`, which could end the new session too — and the record
                // is written once more, over whatever a turn of the old one saved on its
                // way out, even one that was still connecting.
                let recordId = record.acpxRecordId
                _ = try runBlocking { await DaemonClient.releaseSession(sessionId: recordId) }
                try SessionStore.writeRecord(record)
            } else if record.acpSessionId == replaced.acpSessionId {
                // The agent gave the new session the ACP session the replaced record had
                // moved to (a reconnect's fallback, an import): a `session/close` for it
                // would reach the new session. A daemon holding the replaced one lets its
                // agent go, and the replaced record is closed here.
                let recordId = replaced.acpxRecordId
                _ = try runBlocking { await DaemonClient.releaseSession(sessionId: recordId) }
                _ = try markClosed(SessionStore.loadRecord(recordId) ?? replaced)
            } else {
                _ = try close(replaced)
            }
            if flags.verbose {
                Console.errLine("[acpx] soft-closed prior session: \(replaced.acpxRecordId)")
            }
        }
        printCreatedBanner(record, agentName: agent.agentName, flags: flags)
        if flags.verbose {
            let scope = name.map { "named session \"\($0)\"" } ?? "cwd session"
            Console.errLine("[acpx] created \(scope): \(record.acpxRecordId)")
        }
        printNewSession(record, replaced: replaced, format: flags.format)
        return ExitCodes.success
    }

    static func ensure(_ context: CommandContext) throws -> Int32 {
        let scan = context.options
        let flags = try context.globalFlags()
        let permissions = try resolvePermissions(flags, config: context.config)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.parsed("name", parseSessionName)

        let gitRoot = SessionStore.findGitRepositoryRoot(agent.cwd)
        if let existing = SessionStore.findSessionByDirectoryWalk(
            agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, boundary: gitRoot ?? agent.cwd) {
            // Reusing a session still honours `--mcp-config`: ensure promises a
            // session set up the way this invocation asked for.
            let reused = try applyExplicitMcpServers(to: existing, config: context.config)
            printEnsured(reused, created: false, format: flags.format)
            return ExitCodes.success
        }

        let record = try createSession(
            agent: agent, name: name, flags: flags, config: context.config, permissions: permissions)
        printCreatedBanner(record, agentName: agent.agentName, flags: flags)
        printEnsured(record, created: true, format: flags.format)
        return ExitCodes.success
    }

    /// Apply an explicit `--mcp-config` to a session that already exists, so a reused
    /// record ends up with the servers this invocation asked for instead of silently
    /// keeping its old ones. Returns the record to report on.
    ///
    /// A running daemon does it (it owns the live connection, and reconnects it so the
    /// new servers take effect without losing the session); with no daemon running
    /// there is no connection to reconcile, so the record is updated here.
    /// Comparison is on the normalized wire specs, so a set spelled differently but
    /// identical on the wire costs nothing.
    static func applyExplicitMcpServers(
        to record: SessionRecord, config: ResolvedAcpxConfig
    ) throws -> SessionRecord {
        guard let requested = config.sessionMcpServers else { return record }
        let current = try record.acpx?.mcpServers.map { try $0.map { try $0.protocolSpec() } }
        guard try current != requested.map({ try $0.protocolSpec() }) else { return record }

        let sessionId = record.acpSessionId
        do {
            try runBlocking {
                try await DaemonClient.setSessionMcpServers(
                    sessionId: sessionId, mcpServers: requested, restart: true)
            }
        } catch is DaemonUnavailable {
            var updated = record
            var acpx = updated.acpx ?? SessionAcpxState()
            acpx.mcpServers = requested
            updated.acpx = acpx
            try SessionStore.writeRecord(updated)
            return updated
        } catch {
            throw CLIError(error.localizedDescription)
        }
        return SessionStore.loadRecord(record.acpxRecordId) ?? record
    }

    // MARK: - Create (shared engine → record)

    /// acpx's `handleSessionsNew` / `handleSessionsEnsure` resolve the permission mode
    /// and `--permission-policy` first: a bad one fails the command before any session
    /// is closed, reused or started.
    static func resolvePermissions(
        _ flags: GlobalFlags, config: ResolvedAcpxConfig
    ) throws -> (policy: PermissionPolicy, rules: PermissionRules?) {
        (try permissionPolicy(flags, config: config), try flags.permissionRules())
    }

    static func createSession(
        agent: AgentInvocation, name: String?, flags: GlobalFlags, config: ResolvedAcpxConfig,
        permissions: (policy: PermissionPolicy, rules: PermissionRules?)
    ) throws -> SessionRecord {
        let (permission, permissionRules) = permissions
        let meta = sessionMeta(agent: agent, flags: flags)
        let options = sessionOptions(flags)
        // A failure reaches the top level as it is, as acpx's `createSession` throws it:
        // the agent's error with its code and data, an auth policy's with its detail code.
        return try runBlocking {
            // An explicit `--mcp-config` becomes the session's own server set,
            // persisted so the daemon replays it on every reconnect.
            try await SessionEngine.createSession(
                agentCommand: agent.agentCommand, agentArgv: agent.agentArgv, cwd: agent.cwd, name: name,
                permission: permission, permissionRules: permissionRules, authCredentials: config.auth,
                authPolicy: flags.authPolicy, mcpServers: try config.mcpServerSpecs(),
                sessionMcpServers: config.sessionMcpServers,
                meta: meta, sessionOptions: options,
                capabilities: flags.clientCapabilities,
                inheritStderr: flags.verbose,
                onModelWarning: flags.jsonStrict ? nil : { Console.errLine("[acpx] warning: \($0)") })
        }
    }

    /// Collect the per-session options the CLI flags request, or `nil` if none.
    static func sessionOptions(_ flags: GlobalFlags) -> SessionAcpxState.SessionOptions? {
        var options = SessionAcpxState.SessionOptions()
        var any = false
        if let model = flags.model { options.model = model; any = true }
        if let tools = flags.allowedTools { options.allowedTools = tools; any = true }
        if let maxTurns = flags.maxTurns { options.maxTurns = maxTurns; any = true }
        if let prompt = flags.systemPrompt {
            switch prompt {
            case .replace(let text): options.systemPrompt = JSONValue.string(text)
            case .append(let text): options.systemPrompt = JSONValue.object(["append": JSONValue.string(text)])
            }
            any = true
        }
        return any ? options : nil
    }

    /// acpx's `closeSession`, as `sessions close` and `sessions new` close a session: a
    /// running daemon drops its live agent and closes the record itself; with none
    /// reachable nothing is held, and the record is marked closed here. Returns the
    /// record as closed.
    ///
    /// The daemon is told the record by its id, which no other record has: a newer record
    /// can have been written under the ACP session id this one moved to.
    static func close(_ record: SessionRecord) throws -> SessionRecord {
        let recordId = record.acpxRecordId
        let closedByDaemon = try runBlocking {
            await DaemonClient.closeSession(sessionId: recordId)
        }
        if closedByDaemon, let persisted = SessionStore.loadRecord(recordId) {
            return persisted
        }
        return try markClosed(record)
    }

    /// `record` marked closed, as the CLI closes a session no daemon holds.
    static func markClosed(_ record: SessionRecord) throws -> SessionRecord {
        var closed = record
        closed.pid = nil
        closed.closed = true
        closed.closedAt = nowISO()
        try SessionStore.writeRecord(closed)
        return closed
    }

    static func permissionPolicy(_ flags: GlobalFlags, config: ResolvedAcpxConfig) throws -> PermissionPolicy {
        switch try Flags.resolvePermissionMode(flags, default: config.defaultPermissions) {
        case "approve-all": return .approveAll
        case "deny-all": return .denyAll
        default: return .approveReads
        }
    }

    /// The `_meta` for this invocation's `session/new`. acpx sends the session
    /// options for *every* agent — only Claude Code's `settingSources` is gated
    /// on the adapter — so this is not conditioned on the agent name.
    static func sessionMeta(agent: AgentInvocation, flags: GlobalFlags) -> JSONValue? {
        SessionMeta.build(options: sessionOptions(flags), agentCommand: agent.agentCommand)
    }

    // MARK: - Output

    private static func printCreatedBanner(_ record: SessionRecord, agentName: String, flags: GlobalFlags) {
        if flags.format == "quiet" || (flags.jsonStrict && flags.format == "json") { return }
        let label = record.name ?? "cwd"
        Console.errLine("[acpx] created session \(label) (\(record.acpxRecordId))")
        Console.errLine("[acpx] agent: \(agentName)")
        Console.errLine("[acpx] cwd: \(record.cwd)")
    }

    private static func printNewSession(_ record: SessionRecord, replaced: SessionRecord?, format: String) {
        switch format {
        case "json":
            var pairs: [(String, JSONValue?)] = [
                ("action", .string("session_ensured")),
                ("created", .bool(true)),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId)),
                ("agentSessionId", record.agentSessionId.map(JSONValue.string)),
                ("name", record.name.map(JSONValue.string))
            ]
            if let replaced { pairs.append(("replacedSessionId", .string(replaced.acpxRecordId))) }
            Console.out(jsonObject(pairs).compact() + "\n")
        case "quiet":
            Console.out("\(record.acpxRecordId)\n")
        default:
            if let replaced {
                Console.out("\(record.acpxRecordId)\t(replaced \(replaced.acpxRecordId))\n")
            } else {
                Console.out("\(record.acpxRecordId)\n")
            }
        }
    }

    private static func printEnsured(_ record: SessionRecord, created: Bool, format: String) {
        switch format {
        case "json":
            Console.out(jsonObject([
                ("action", .string("session_ensured")),
                ("created", .bool(created)),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId)),
                ("agentSessionId", record.agentSessionId.map(JSONValue.string)),
                ("name", record.name.map(JSONValue.string))
            ]).compact() + "\n")
        case "quiet":
            Console.out("\(record.acpxRecordId)\n")
        default:
            Console.out("\(record.acpxRecordId)\t(\(created ? "created" : "existing"))\n")
        }
    }
}
