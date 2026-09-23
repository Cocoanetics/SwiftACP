import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `sessions new` / `sessions ensure` — create (or reuse) a session by spawning
/// the agent directly via ACP (no daemon), matching acpx's `createSession`.
enum SessionLifecycle {
    static func new(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([
            OptionSpec("name", short: "s", takesValue: true, value: "name"),
            OptionSpec("resume-session", takesValue: true, value: "id")
        ])
        let flags = try context.globalFlags(scan)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.parsed("name", parseSessionName)

        let replaced = SessionStore.findSession(
            agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, includeClosed: false)
        if let replaced {
            try softClose(replaced)
            if flags.verbose {
                Console.errLine("[acpx] soft-closed prior session: \(replaced.acpxRecordId)")
            }
        }

        let record = try createSession(agent: agent, name: name, flags: flags, config: context.config)
        printCreatedBanner(record, agentName: agent.agentName, flags: flags)
        if flags.verbose {
            let scope = name.map { "named session \"\($0)\"" } ?? "cwd session"
            Console.errLine("[acpx] created \(scope): \(record.acpxRecordId)")
        }
        printNewSession(record, replaced: replaced, format: flags.format)
        return ExitCodes.success
    }

    static func ensure(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([
            OptionSpec("name", short: "s", takesValue: true, value: "name"),
            OptionSpec("resume-session", takesValue: true, value: "id")
        ])
        let flags = try context.globalFlags(scan)
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

        let record = try createSession(agent: agent, name: name, flags: flags, config: context.config)
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

    static func createSession(
        agent: AgentInvocation, name: String?, flags: GlobalFlags, config: ResolvedAcpxConfig
    ) throws -> SessionRecord {
        let permission = try permissionPolicy(flags, config: config)
        let meta = sessionMeta(agent: agent, flags: flags)
        let options = sessionOptions(flags)
        return try runBlocking {
            do {
                // An explicit `--mcp-config` becomes the session's own server set,
                // persisted so the daemon replays it on every reconnect.
                return try await SessionEngine.createSession(
                    agentCommand: agent.agentCommand, cwd: agent.cwd, name: name,
                    permission: permission, authCredentials: config.auth,
                    authPolicy: flags.authPolicy, mcpServers: try config.mcpServerSpecs(),
                    sessionMcpServers: config.sessionMcpServers,
                    meta: meta, sessionOptions: options,
                    capabilities: flags.clientCapabilities,
                    inheritStderr: flags.verbose)
            } catch {
                throw CLIError(error.localizedDescription)
            }
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

    private static func softClose(_ record: SessionRecord) throws {
        var record = record
        record.pid = nil
        record.closed = true
        record.closedAt = nowISO()
        try SessionStore.writeRecord(record)
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
            var pairs: [(String, JSONValue)] = [
                ("action", .string("session_ensured")),
                ("created", .bool(true)),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId)),
                ("agentSessionId", record.agentSessionId.map(JSONValue.string) ?? .null),
                ("name", record.name.map(JSONValue.string) ?? .null)
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
                ("agentSessionId", record.agentSessionId.map(JSONValue.string) ?? .null),
                ("name", record.name.map(JSONValue.string) ?? .null)
            ]).compact() + "\n")
        case "quiet":
            Console.out("\(record.acpxRecordId)\n")
        default:
            Console.out("\(record.acpxRecordId)\t(\(created ? "created" : "existing"))\n")
        }
    }
}
