import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `acpx compare <agent>... '<prompt>'` — run one prompt across multiple agents
/// and summarize timing/results (ported from compare-command.ts).
enum CompareCommand {
    private static let defaultTimeoutMs = 300_000
    private static let previewChars = 200

    struct Row {
        var agent: String
        var status: String
        var stopReason: String?
        var wallMs: Int
        var finalMessage: String
        var error: String?
        /// acpx's `permission_requests` and `permission_denied` (denied or cancelled).
        var permissionRequests = 0
        var permissionDenied = 0
    }

    /// What one agent's run came to: the turn, if it finished, and the permissions it
    /// needed either way — acpx's `onPermissionStats` capture.
    private struct Ran {
        var outcome: PromptOutcome?
        var permissions = PermissionStats()
        var error: Error?
    }

    static func run(_ context: CommandContext) throws -> Int32 {
        if context.config.disableExec {
            throw CLIError("compare subcommand is disabled by configuration (disableExec: true)")
        }
        let scan = context.options
        var flags = try context.globalFlags()
        // The root's `--cwd` overwrites compare's own in the merged options; acpx then puts
        // compare's own back.
        if let cwd = context.ownOptions.string("cwd") {
            flags.cwd = ACPXPaths.resolve(cwd, base: physicalCWD())
        }
        if let agent = flags.agent, !agent.isEmpty {
            throw InvalidArgumentError("Do not combine compare with --agent; pass agent names")
        }
        let format = scan.flag("json") ? "json" : flags.format
        let permissionRules = try flags.permissionRules()

        let promptFile = scan.string("file") ?? scan.string("prompt-file")
        let (agents, promptText) = try splitArgs(context.positionals, promptFile: promptFile)
        let prompt = try PromptInputResolver.contentBlocks(PromptInputResolver.resolve(
            words: promptText.isEmpty ? [] : [promptText], file: promptFile, cwd: flags.cwd))

        var rows: [Row] = []
        for agentName in agents {
            rows.append(try runAgent(
                agentName, prompt: prompt, flags: flags, config: context.config, permissionRules: permissionRules))
        }
        printRows(rows, format: format)

        if rows.contains(where: { $0.status == "error" }) { return ExitCodes.error }
        if rows.contains(where: { $0.status == "permission_denied" }) { return ExitCodes.permissionDenied }
        if rows.contains(where: { $0.status == "cancelled" }) { return ExitCodes.timeout }
        return ExitCodes.success
    }

    private static func splitArgs(_ args: [String], promptFile: String?) throws -> ([String], String) {
        if promptFile != nil {
            if args.isEmpty { throw InvalidArgumentError("At least one agent is required") }
            return (args, "")
        }
        guard args.count >= 2 else {
            throw InvalidArgumentError("Usage: acpx compare <agent>... '<prompt>'")
        }
        return (Array(args.dropLast()), args.last!)
    }

    private static func runAgent(
        _ agentName: String, prompt: [ContentBlock], flags: GlobalFlags,
        config: ResolvedAcpxConfig, permissionRules: PermissionRules?
    ) throws -> Row {
        let invocation = try Flags.resolveAgentInvocation(agentName, flags, config: config)
        let permission = try SessionLifecycle.permissionPolicy(flags, config: config)
        let mcpServers = try config.mcpServerSpecs()
        let agentCommand = invocation.agentCommand
        let agentArgv = invocation.agentArgv
        let cwd = invocation.cwd
        let start = Date()
        let ran: Ran = try runBlocking {
            let handle: ACPAgent
            do {
                // acpx's `runOnce` takes the invocation's connection options, the
                // non-interactive policy among them.
                handle = try await ACPAgent.launch(
                    agent: agentCommand, argv: agentArgv, cwd: cwd, permission: permission,
                    nonInteractivePermissions: flags.nonInteractivePolicy, permissionRules: permissionRules,
                    capabilities: flags.clientCapabilities,
                    authCredentials: config.auth, authPolicy: flags.authPolicy,
                    inheritStderr: false)
            } catch {
                return Ran(error: error)
            }
            var ran = Ran()
            var sessionId: SessionId?
            do {
                let session = try await handle.newSession(mcpServers: mcpServers)
                sessionId = session.id
                ran.outcome = try await session.run(prompt)
            } catch {
                ran.error = error
            }
            if let sessionId { ran.permissions = await handle.connection.permissionStats(for: sessionId) }
            await handle.close()
            return ran
        }
        return row(agentName, ran, wallMs: Int(Date().timeIntervalSince(start) * 1000))
    }

    /// acpx's `buildSuccessRow` / `buildErrorRow`. A turn that needed a permission
    /// question nobody could be asked fails as acpx's `runOnce` fails it — an error
    /// row, `permission_denied` — keeping what the agent said.
    private static func row(_ agentName: String, _ ran: Ran, wallMs: Int) -> Row {
        let stats = ran.permissions
        var row = Row(
            agent: agentName, status: "ok", stopReason: nil, wallMs: wallMs,
            finalMessage: truncate(collapse(ran.outcome?.text ?? ""), previewChars), error: nil,
            permissionRequests: stats.requested, permissionDenied: stats.denied + stats.cancelled)
        if let error = ran.error {
            row.status = "error"
            row.error = truncate(collapse(error.localizedDescription), previewChars)
        } else if stats.promptUnavailable {
            row.status = "permission_denied"
            row.error = PermissionPromptUnavailableError().description
        } else if let outcome = ran.outcome {
            row.stopReason = outcome.stopReason.rawValue
            row.status = outcome.stopReason == .cancelled ? "cancelled"
                : stats.denied + stats.cancelled > 0 ? "permission_denied" : "ok"
        }
        return row
    }

    // MARK: Output

    private static func printRows(_ rows: [Row], format: String) {
        switch format {
        case "json":
            // acpx's rows carry `null` where a value is missing, not an absent key.
            Console.out(WireJSON.array(rows.map { row in
                jsonObject([
                    ("agent", .string(row.agent)),
                    ("status", .string(row.status)),
                    ("stop_reason", row.stopReason.map(JSONValue.string) ?? .null),
                    ("wall_ms", .integer(row.wallMs)),
                    ("input_tokens", .null),
                    ("output_tokens", .null),
                    ("total_tokens", .null),
                    ("final_message", .string(row.finalMessage)),
                    ("error", row.error.map(JSONValue.string) ?? .null),
                    ("permission_requests", .integer(row.permissionRequests)),
                    ("permission_denied", .integer(row.permissionDenied))
                ])
            }).compact() + "\n")
        case "quiet":
            for row in rows { Console.out("\(row.agent)\t\(row.status)\n") }
        default:
            Console.out(renderTable(rows) + "\n")
        }
    }

    private static func renderTable(_ rows: [Row]) -> String {
        let headers = [
            "agent", "status", "wall_ms", "input", "output", "total", "permissions",
            "stop_reason", "final_message", "error"
        ]
        let body = rows.map { row in
            [row.agent, row.status, String(row.wallMs), "-", "-", "-",
             "\(row.permissionDenied)/\(row.permissionRequests)", row.stopReason ?? "-",
             row.finalMessage.isEmpty ? "-" : collapse(row.finalMessage), row.error ?? "-"]
        }
        var widths = headers.map(\.count)
        for cells in body {
            for (i, cell) in cells.enumerated() { widths[i] = max(widths[i], cell.count) }
        }
        func formatRow(_ cells: [String]) -> String {
            cells.enumerated().map { i, cell in
                truncate(cell, widths[i]).padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingTrailing()
        }
        var lines = [formatRow(headers)]
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        for cells in body { lines.append(formatRow(cells)) }
        return lines.joined(separator: "\n")
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func truncate(_ s: String, _ max: Int) -> String {
        if s.count <= max { return s }
        if max <= 3 { return String(s.prefix(max)) }
        return String(s.prefix(max - 3)) + "..."
    }
}

extension String {
    fileprivate func trimmingTrailing() -> String {
        var s = Substring(self)
        while let last = s.last, last == " " { s = s.dropLast() }
        return String(s)
    }
}
