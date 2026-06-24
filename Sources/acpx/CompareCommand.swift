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
    }

    static func run(_ context: CommandContext) throws -> Int32 {
        if context.config.disableExec {
            throw CLIError("compare subcommand is disabled by configuration (disableExec: true)")
        }
        let scan = try context.scan([
            OptionSpec("file", short: "f", takesValue: true),
            OptionSpec("prompt-file", takesValue: true), OptionSpec("json")
        ])
        let flags = try context.globalFlags(scan)
        if let agent = flags.agent, !agent.isEmpty {
            throw UsageError("Do not combine compare with --agent; pass agent names")
        }
        let format = scan.flag("json") ? "json" : flags.format

        let promptFile = scan.string("file") ?? scan.string("prompt-file")
        let (agents, promptText) = try splitArgs(context.positionals, promptFile: promptFile)
        let prompt = try PromptInputResolver.resolve(
            words: promptText.isEmpty ? [] : [promptText], file: promptFile, cwd: flags.cwd)

        var rows: [Row] = []
        for agentName in agents {
            rows.append(try runAgent(agentName, prompt: prompt, flags: flags, config: context.config))
        }
        printRows(rows, format: format)

        if rows.contains(where: { $0.status == "error" }) { return ExitCodes.error }
        if rows.contains(where: { $0.status == "permission_denied" }) { return ExitCodes.permissionDenied }
        if rows.contains(where: { $0.status == "cancelled" }) { return ExitCodes.timeout }
        return ExitCodes.success
    }

    private static func splitArgs(_ args: [String], promptFile: String?) throws -> ([String], String) {
        if promptFile != nil {
            if args.isEmpty { throw UsageError("At least one agent is required") }
            return (args, "")
        }
        guard args.count >= 2 else {
            throw UsageError("Usage: acpx compare <agent>... '<prompt>'")
        }
        return (Array(args.dropLast()), args.last!)
    }

    private static func runAgent(
        _ agentName: String, prompt: String, flags: GlobalFlags, config: ResolvedAcpxConfig
    ) throws -> Row {
        let invocation = try Flags.resolveAgentInvocation(agentName, flags, config: config)
        let permission = try SessionLifecycle.permissionPolicy(flags, config: config)
        let agentCommand = invocation.agentCommand
        let cwd = invocation.cwd
        let start = Date()
        do {
            let outcome: PromptOutcome = try runBlocking {
                let handle = try await ACPAgent.launch(
                    agent: agentCommand, cwd: cwd, permission: permission,
                    authCredentials: config.auth, authPolicy: flags.authPolicy,
                    inheritStderr: false)
                do {
                    let session = try await handle.newSession()
                    let result = try await session.run(prompt)
                    await handle.close()
                    return result
                } catch {
                    await handle.close()
                    throw error
                }
            }
            let wallMs = Int(Date().timeIntervalSince(start) * 1000)
            let status = outcome.stopReason == .cancelled ? "cancelled" : "ok"
            return Row(
                agent: agentName, status: status, stopReason: outcome.stopReason.rawValue,
                wallMs: wallMs, finalMessage: truncate(collapse(outcome.text), previewChars), error: nil)
        } catch {
            let wallMs = Int(Date().timeIntervalSince(start) * 1000)
            return Row(
                agent: agentName, status: "error", stopReason: nil, wallMs: wallMs,
                finalMessage: "", error: truncate(collapse(error.localizedDescription), previewChars))
        }
    }

    // MARK: Output

    private static func printRows(_ rows: [Row], format: String) {
        switch format {
        case "json":
            Console.out(JSONValue.array(rows.map { row in
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
                    ("permission_requests", .integer(0)),
                    ("permission_denied", .integer(0))
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
            [row.agent, row.status, String(row.wallMs), "-", "-", "-", "0/0",
             row.stopReason ?? "-", row.finalMessage.isEmpty ? "-" : collapse(row.finalMessage),
             row.error ?? "-"]
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
