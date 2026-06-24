import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `acpx [<agent>] sessions [<sub>]` — list/inspect/manage local sessions.
enum SessionsCommand {
    static let subcommands: Set<String> = [
        "list", "new", "ensure", "close", "show", "history", "read", "export", "import", "prune"
    ]

    static func run(_ context: CommandContext) throws -> Int32 {
        let sub = context.positionals.first.flatMap { subcommands.contains($0) ? $0 : nil }
        // Bare `sessions` runs list; a recognized sub strips that token.
        let rest = sub == nil ? context.positionals : Array(context.positionals.dropFirst())
        let ctx = CommandContext(
            explicitAgent: context.explicitAgent, positionals: rest, rawArgs: context.rawArgs,
            config: context.config)

        switch sub ?? "list" {
        case "list": return try list(ctx)
        case "show": return try show(ctx)
        case "history": return try history(ctx, defaultLimit: DEFAULT_HISTORY_LIMIT, tail: false)
        case "read": return try history(ctx, defaultLimit: 0, tail: true)
        case "close": return try close(ctx)
        case "prune": return try prune(ctx)
        case "new": return try SessionLifecycle.new(ctx)
        case "ensure": return try SessionLifecycle.ensure(ctx)
        case "export": throw CLIError("sessions export: not yet implemented")
        case "import": throw CLIError("sessions import: not yet implemented")
        default: throw UsageError("unknown command '\(sub ?? "")'")
        }
    }

    // MARK: list

    private static func list(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([
            OptionSpec("local"), OptionSpec("cursor", takesValue: true),
            OptionSpec("filter-cwd", takesValue: true)
        ])
        let flags = try context.globalFlags(scan)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let filterCwd = scan.string("filter-cwd").map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: agent.cwd)).standardizedFileURL.path
        }
        // Agents we target (codex/claude) don't advertise session/list, so acpx
        // falls back to local records. --local additionally honors --filter-cwd.
        let effectiveFilter = scan.flag("local") ? filterCwd : nil
        var records = SessionStore.listSessions(forAgent: agent.agentCommand)
        if let effectiveFilter {
            records = records.filter { $0.cwd == effectiveFilter }
        }
        printSessions(records, format: flags.format)
        return ExitCodes.success
    }

    static func printSessions(_ records: [SessionRecord], format: String) {
        switch format {
        case "json":
            Console.out(jsonString(records) + "\n")
        case "quiet":
            for r in records { Console.out("\(r.acpxRecordId)\(r.closed == true ? " [closed]" : "")\n") }
        default:
            if records.isEmpty {
                Console.out("No sessions\n")
            } else {
                for r in records {
                    let closed = r.closed == true ? " [closed]" : ""
                    Console.out("\(r.acpxRecordId)\(closed)\t\(r.name ?? "-")\t\(r.cwd)\t\(r.lastUsedAt)\n")
                }
            }
        }
    }

    // MARK: show

    private static func show(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([])
        let flags = try context.globalFlags(scan)
        let record = try findScopedSessionOrThrow(context, flags, name: context.positionals.first)
        switch flags.format {
        case "json":
            Console.out(jsonString(record) + "\n")
        case "quiet":
            Console.out("\(record.acpxRecordId)\n")
        default:
            for line in sessionDetailsLines(record) { Console.out(line + "\n") }
        }
        return ExitCodes.success
    }

    private static func sessionDetailsLines(_ r: SessionRecord) -> [String] {
        func d(_ v: Any?) -> String { v.map { "\($0)" } ?? "-" }
        return [
            "id: \(r.acpxRecordId)",
            "sessionId: \(r.acpSessionId)",
            "agentSessionId: \(d(r.agentSessionId))",
            "agent: \(r.agentCommand)",
            "cwd: \(r.cwd)",
            "name: \(d(r.name))",
            "created: \(r.createdAt)",
            "lastActivity: \(r.lastUsedAt)",
            "lastPrompt: \(d(r.lastPromptAt))",
            "closed: \(r.closed == true ? "yes" : "no")",
            "closedAt: \(d(r.closedAt))",
            "pid: \(d(r.pid))",
            "agentStartedAt: \(d(r.agentStartedAt))",
            "lastExitCode: \(d(r.lastAgentExitCode?.value))",
            "lastExitSignal: \(d(r.lastAgentExitSignal?.value))",
            "lastExitAt: \(d(r.lastAgentExitAt))",
            "disconnectReason: \(d(r.lastAgentDisconnectReason))",
            "historyEntries: \(SessionStore.conversationHistoryEntries(r).count)"
        ]
    }

    // MARK: history / read

    private static func history(_ context: CommandContext, defaultLimit: Int, tail: Bool) throws -> Int32 {
        let scan = try context.scan([
            OptionSpec(tail ? "tail" : "limit", takesValue: true)
        ])
        let flags = try context.globalFlags(scan)
        let limit: Int
        if tail {
            limit = try scan.string("tail").map(parseHistoryLimit) ?? 0
        } else {
            limit = try scan.string("limit").map(parseHistoryLimit) ?? defaultLimit
        }
        let record = try findScopedSessionOrThrow(context, flags, name: context.positionals.first)
        let all = SessionStore.conversationHistoryEntries(record)
        let visible = limit == 0 ? all : Array(all.suffix(limit))

        switch flags.format {
        case "json":
            let entries = JSONValue.array(visible.map {
                jsonObject([
                    ("role", .string($0.role)),
                    ("timestamp", .string($0.timestamp)),
                    ("textPreview", .string($0.textPreview))
                ])
            })
            Console.out(jsonString(jsonObject([
                ("id", .string(record.acpxRecordId)),
                ("sessionId", .string(record.acpSessionId)),
                ("limit", .integer(limit)),
                ("count", .integer(visible.count)),
                ("entries", entries)
            ])) + "\n")
        case "quiet":
            for e in visible { Console.out("\(e.textPreview)\n") }
        default:
            Console.out("session: \(record.acpxRecordId) (\(visible.count)/\(all.count) shown)\n")
            if visible.isEmpty {
                Console.out("No history\n")
            } else {
                for e in visible { Console.out("\(e.timestamp)\t\(e.role)\t\(e.textPreview)\n") }
            }
        }
        return ExitCodes.success
    }

    // MARK: close

    private static func close(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([])
        let flags = try context.globalFlags(scan)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try context.positionals.first.map(parseSessionName)
        guard var record = SessionStore.findSession(
            agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, includeClosed: false)
        else {
            throw CLIError(missingScopedSessionMessage(agent: agent, name: name))
        }
        // (Daemon termination is wired once acpxd exists; mark closed locally.)
        record.pid = nil
        record.closed = true
        record.closedAt = nowISO()
        try SessionStore.writeRecord(record)

        switch flags.format {
        case "json":
            Console.out(jsonString(jsonObject([
                ("action", .string("session_closed")),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId)),
                ("agentSessionId", record.agentSessionId.map(JSONValue.string) ?? .null)
            ])) + "\n")
        case "quiet":
            break
        default:
            Console.out("\(record.acpxRecordId)\n")
        }
        return ExitCodes.success
    }

    // MARK: prune

    private static func prune(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([
            OptionSpec("dry-run"), OptionSpec("include-history"),
            OptionSpec("before", takesValue: true), OptionSpec("older-than", takesValue: true)
        ])
        let flags = try context.globalFlags(scan)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let dryRun = scan.flag("dry-run")
        let includeHistory = scan.flag("include-history")
        let before = try scan.string("before").map(parseBeforeDate)
        let olderThanDays = try scan.string("older-than").map(parseDaysOlderThan)

        var cutoff: String?
        if let before {
            cutoff = isoString(before)
        } else if let olderThanDays {
            cutoff = isoString(Date().addingTimeInterval(-Double(olderThanDays) * 86400))
        }

        let candidates = SessionStore.listSessions(forAgent: agent.agentCommand).filter { record in
            guard record.closed == true else { return false }
            guard let cutoff else { return true }
            return (record.closedAt ?? record.lastUsedAt) < cutoff
        }

        var bytesFreed = 0
        if !dryRun {
            for record in candidates {
                bytesFreed += SessionStore.deleteRecord(record.acpxRecordId, includeHistory: includeHistory)
            }
        }
        printPruneResult(candidates, bytesFreed: bytesFreed, dryRun: dryRun, format: flags.format)
        return ExitCodes.success
    }

    private static func printPruneResult(
        _ pruned: [SessionRecord], bytesFreed: Int, dryRun: Bool, format: String
    ) {
        let count = pruned.count
        switch format {
        case "json":
            Console.out(jsonString(jsonObject([
                ("action", .string(dryRun ? "sessions_prune_dry_run" : "sessions_pruned")),
                ("dryRun", .bool(dryRun)),
                ("count", .integer(count)),
                ("bytesFreed", .integer(bytesFreed)),
                ("pruned", .array(pruned.map { JSONValue.string($0.acpxRecordId) }))
            ])) + "\n")
        case "quiet":
            for r in pruned { Console.out("\(r.acpxRecordId)\n") }
        default:
            if count == 0 {
                Console.out(dryRun ? "[DRY RUN] No sessions to prune\n" : "No sessions pruned\n")
                return
            }
            let prefix = dryRun ? "[DRY RUN] Would prune" : "Pruned"
            let bytes = (!dryRun && bytesFreed > 0) ? ", freed \(formatBytes(bytesFreed))" : ""
            Console.out("\(prefix) \(count) session\(count == 1 ? "" : "s")\(bytes)\n")
            for r in pruned {
                let label = r.name.map { " (\($0))" } ?? ""
                Console.out("  \(r.acpxRecordId)\(label)\t\(r.closedAt ?? r.lastUsedAt)\n")
            }
        }
    }

    // MARK: helpers

    static func findScopedSessionOrThrow(
        _ context: CommandContext, _ flags: GlobalFlags, name rawName: String?
    ) throws -> SessionRecord {
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try rawName.map(parseSessionName)
        guard let record = SessionStore.findSession(
            agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, includeClosed: true)
        else {
            throw CLIError(missingScopedSessionMessage(agent: agent, name: name))
        }
        return record
    }

    static func missingScopedSessionMessage(agent: AgentInvocation, name: String?) -> String {
        if let name {
            return "No named session \"\(name)\" for cwd \(agent.cwd) and agent \(agent.agentName)"
        }
        return "No cwd session for \(agent.cwd) and agent \(agent.agentName)"
    }
}

// MARK: - misc helpers

private nonisolated(unsafe) let pruneISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private func isoString(_ date: Date) -> String { pruneISO.string(from: date) }

private func parseBeforeDate(_ value: String) throws -> Date {
    if let date = pruneISO.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.timeZone = TimeZone(identifier: "UTC")
    if let date = plain.date(from: value) { return date }
    let dayOnly = DateFormatter()
    dayOnly.dateFormat = "yyyy-MM-dd"
    dayOnly.timeZone = TimeZone(identifier: "UTC")
    if let date = dayOnly.date(from: value) { return date }
    throw UsageError("--before must be a valid date (e.g. 2026-01-01 or 2026-01-01T00:00:00Z)")
}

func formatBytes(_ bytes: Int) -> String {
    let b = Double(bytes)
    if bytes >= 1_073_741_824 { return "\(String(format: "%.1f", b / 1_073_741_824)) GB" }
    if bytes >= 1_048_576 { return "\(String(format: "%.1f", b / 1_048_576)) MB" }
    if bytes >= 1024 { return "\(String(format: "%.1f", b / 1024)) KB" }
    return "\(bytes) B"
}
