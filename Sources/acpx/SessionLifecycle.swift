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
        let resumeSessionId = scan.string("resume-session")

        let replaced = SessionStore.findSession(
            agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, includeClosed: false)
        // Resuming the session it replaces writes that one anew, closed first as any resumed
        // record is (``createSession(agent:name:flags:config:permissions:resumeSessionId:)``):
        // there is nothing more to close (acpx's `resumesSameRecord`).
        let resumesSameRecord = replaced != nil && replaced?.acpxRecordId == resumeSessionId
        // The daemon that closes the replaced session is this acpx's own, or nothing is done
        // (#162).
        if replaced != nil, !resumesSameRecord { try runBlocking { try await DaemonClient.requireMatchingDaemon() } }
        // The new session first, then the one it replaces closed, as acpx 0.19.3 has it (#778,
        // for our openclaw/acpx#767): a creation that fails leaves that one open. The new record
        // has an id of its own, so the close reaches the replaced one whatever id the agent gave
        // the new session (acpx 0.19.4, for our openclaw/acpx#805).
        let record = try createSession(
            agent: agent, name: name, flags: flags, config: context.config, permissions: permissions,
            resumeSessionId: resumeSessionId)
        if let replaced {
            if !resumesSameRecord { _ = try close(replaced) }
            noteSoftClosed(replaced, flags)
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

        // Found or made under the scope's ownership, as acpx's `ensureSession` takes it (#784):
        // of two ensures — or an ensure and an import — that find no session, one makes it.
        let scope = try SessionOwnership.scope(agentCommand: agent.agentCommand, cwd: agent.cwd, name: name)
        let (record, created) = try scope.holding { () throws -> (SessionRecord, Bool) in
            let gitRoot = SessionStore.findGitRepositoryRoot(agent.cwd)
            if let existing = SessionStore.findSessionByDirectoryWalk(
                agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, boundary: gitRoot ?? agent.cwd) {
                // A session found is kept as it is: its MCP servers are each prompt's own, as in
                // acpx (#245).
                var reused = existing
                // And `--model`, as acpx's `ensureSessionWithOwnership` puts it on the session it
                // keeps (`setSessionModel`), which fails the command if the session cannot take it.
                if let model = flags.model {
                    reused = try setModel(model, on: reused, flags: flags, config: context.config)
                }
                return (reused, false)
            }
            let record = try createSession(
                agent: agent, name: name, flags: flags, config: context.config, permissions: permissions,
                resumeSessionId: scan.string("resume-session"))
            return (record, true)
        }
        if created { printCreatedBanner(record, agentName: agent.agentName, flags: flags) }
        printEnsured(record, created: created, format: flags.format)
        return ExitCodes.success
    }

    /// Put `model` on `record`'s session through acpxd, as `set model` does, and return the
    /// record as that leaves it.
    private static func setModel(
        _ model: String, on record: SessionRecord, flags: GlobalFlags, config: ResolvedAcpxConfig
    ) throws -> SessionRecord {
        let recordId = record.acpxRecordId
        let terminalOutputCeiling = try TerminalOutputLimit.ceiling()
        _ = try runBlocking {
            do {
                return try await DaemonClient.setModel(
                    sessionId: recordId, modelId: model, nonInteractivePermissions: flags.nonInteractivePermissions,
                    terminalOutputCeiling: terminalOutputCeiling, timeoutMs: flags.timeoutMs, verbose: flags.verbose,
                    client: flags.clientOptions(config: config))
            } catch let unavailable as DaemonUnavailable {
                throw CLIError(unavailable.cliMessage)
            }
        }
        return SessionStore.loadRecord(recordId) ?? record
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

    /// acpx's `createSessionWithClient`: a new session, or with `resumeSessionId` the one
    /// taken back. A record under that id, of the same agent, is the one resumed, as acpx
    /// 0.19.4 has it: closed first when open (#782, #785), its ACP session is the one taken
    /// back, and it is written anew under its own id, even from another scope. Any other id is
    /// an ACP session's, taken back under a record of its own: another agent's record under
    /// that id is left as it is (openclaw/acpx#825).
    static func createSession(
        agent: AgentInvocation, name: String?, flags: GlobalFlags, config: ResolvedAcpxConfig,
        permissions: (policy: PermissionPolicy, rules: PermissionRules?), resumeSessionId: String? = nil
    ) throws -> SessionRecord {
        let resumed = try resumeTarget(resumeSessionId, agent: agent)
        let (permission, permissionRules) = permissions
        let meta = sessionMeta(agent: agent, flags: flags)
        let options = sessionOptions(flags)
        // A failure reaches the top level as it is, as acpx's `createSession` throws it:
        // the agent's error with its code and data, an auth policy's with its detail code.
        return try runBlocking {
            // The invocation's servers — its `--mcp-config` file's, else its config files' — as acpx
            // gives them to `session/new`; the record keeps none (#245).
            try await SessionEngine.createSession(
                agentCommand: agent.agentCommand, agentArgv: agent.agentArgv, cwd: agent.cwd, name: name,
                permission: permission, permissionRules: permissionRules, authCredentials: config.auth,
                authPolicy: flags.authPolicy, mcpServers: try config.mcpServerSpecs(), meta: meta,
                resumeSessionId: resumed.sessionId, recordId: resumed.recordId, sessionOptions: options,
                capabilities: flags.clientCapabilities, timeoutMilliseconds: flags.timeoutMs,
                inheritStderr: flags.verbose, onLog: flags.clientLog,
                onModelWarning: flags.jsonStrict ? nil : { Console.errLine("[acpx] warning: \($0)") })
        }
    }

    /// What `--resume-session <id>` takes back, and the record it is written under: a record
    /// under the id, of the same agent, is closed first when open, and its ACP session is taken
    /// back under its id; any other id is an ACP session's, taken back under a record of its own.
    private static func resumeTarget(
        _ id: String?, agent: AgentInvocation
    ) throws -> (sessionId: String?, recordId: String?) {
        guard let id, let resumed = SessionStore.loadRecord(id), resumed.agentCommand == agent.agentCommand else {
            return (id, nil)
        }
        if resumed.closed != true { _ = try close(resumed) }
        return (resumed.acpSessionId, resumed.acpxRecordId)
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
    /// reachable nothing is held, and the record is marked closed here. Either way an agent
    /// the record's pid still names — left running where no daemon held it — is ended, as
    /// acpx ends it (``StrayAgent``). Returns the record as closed.
    ///
    /// The daemon is told the record by its id, which no other record has: other records can
    /// be on the same ACP session.
    static func close(_ record: SessionRecord) throws -> SessionRecord {
        let recordId = record.acpxRecordId
        let closedByDaemon = try runBlocking {
            try await DaemonClient.closeSession(sessionId: recordId)
        }
        StrayAgent.end(namedBy: record)
        if closedByDaemon, let persisted = SessionStore.loadRecord(recordId) {
            return persisted
        }
        return try markClosed(record)
    }

    private static func noteSoftClosed(_ replaced: SessionRecord, _ flags: GlobalFlags) {
        if flags.verbose {
            Console.errLine("[acpx] soft-closed prior session: \(replaced.acpxRecordId)")
        }
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
