import ACPXCore
import Foundation
import JSONFoundation

// `sessions export` and `sessions import`: a session as a portable archive, acpx's
// `handleSessionsExport` and `handleSessionsImport`. Split from `SessionsCommand.swift`.
extension SessionsCommand {
    /// `sessions export [name] --output <path> [--cwd <cwd>]`: the session the agent,
    /// directory and name pick — an open one first, else a closed one — to an archive.
    static func export(_ context: CommandContext) throws -> Int32 {
        let flags = try context.globalFlags()
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let output = try context.ownOptions.parsed("output") { try parseNonEmptyValue("Output path", $0) } ?? ""
        let cwd = try context.ownOptions.parsed("source-cwd") { try parseNonEmptyValue("Session cwd", $0) }
            .map { ACPXPaths.resolve($0, base: agent.cwd) } ?? agent.cwd
        let name = try context.positionals.first.map(parseSessionName)
        // acpx's `loadSessionRecord`: the open session first, then any record of the three.
        guard let record = SessionStore.findSession(agentCommand: agent.agentCommand, cwd: cwd, name: name)
            ?? SessionStore.listSessions().first(where: {
                $0.agentCommand == agent.agentCommand && $0.cwd == cwd && $0.name == name
            })
        else { throw SessionArchive.Refusal("session not found", "not-found") }
        try SessionArchive.export(record, agentName: flags.agent == nil ? agent.agentName : nil, to: output)
        switch flags.format {
        case "json":
            Console.out(jsonObject([("action", .string("session_exported")), ("output", .string(output))])
                .compact() + "\n")
        case "quiet":
            Console.out("\(output)\n")
        default:
            Console.out("exported session to \(output)\n")
        }
        return ExitCodes.success
    }

    /// `sessions import <archive-path> [--name <name>] [--cwd <cwd>]`: an archive as a new
    /// session for the agent, at `--cwd` or where the archive says.
    static func importArchive(_ context: CommandContext) throws -> Int32 {
        let flags = try context.globalFlags()
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let options = context.ownOptions
        let imported = try SessionArchive.importArchive(
            at: try parseNonEmptyValue("Archive path", context.positionals.first ?? ""),
            name: try options.parsed("name", parseSessionName),
            cwd: try options.parsed("destination-cwd") { try parseNonEmptyValue("Imported session cwd", $0) }
                .map { ACPXPaths.resolve($0, base: flags.cwd) },
            expectedAgentName: flags.agent == nil ? agent.agentName : nil, expectedAgentCommand: agent.agentCommand,
            expectedAgentArgv: agent.agentArgv)
        switch flags.format {
        case "json":
            Console.out(jsonObject([
                ("action", .string("session_imported")), ("record_id", .string(imported.recordId)),
                ("cwd", .string(imported.cwd))
            ]).compact() + "\n")
        case "quiet":
            Console.out("\(imported.recordId)\n")
        default:
            Console.out("imported session \(imported.recordId) at \(imported.cwd)\n")
        }
        return ExitCodes.success
    }
}
