import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `acpx compare <agent>... '<prompt>'` — one prompt across several agents, a row for
/// each (ported from compare-command.ts). Each agent runs as acpx's `runOnce` runs it
/// there, along `exec`'s path (``runOnce(_:_:)``): its output discarded, what the agent
/// said and the usage it reported kept for the row. A signal puts the agent running down
/// as `exec`'s run is put down, admits no further agent, and ends `compare` `INTERRUPTED`
/// (130) once the rows are out.
enum CompareCommand {
    /// acpx's `DEFAULT_COMPARE_TIMEOUT_MS`: each run's `--timeout`, unless given one.
    static let defaultTimeoutMs = 300_000
    /// acpx's `FINAL_MESSAGE_PREVIEW_CHARS`.
    static let previewChars = 200

    /// acpx's `CompareRow`.
    struct Row {
        var agent: String
        var status: String
        var stopReason: String?
        var wallMs: Int
        var usage = TokenUsage()
        var finalMessage: String
        var error: String?
        /// acpx's `permission_requests` and `permission_denied` (denied or cancelled).
        var permissionRequests = 0
        var permissionDenied = 0
        /// The answer's `_meta`, as the agent sent it: acpx's `result._meta`, on a row whose
        /// run was answered with one.
        var meta: WireJSON?

        /// The row of a run a signal came during: `cancelled`, as `Interrupted`.
        var interrupted: Row {
            var row = self
            row.status = "cancelled"
            row.error = "Interrupted"
            return row
        }
    }

    /// acpx's `SessionTokenUsage` as `captureUsage` fills it: JavaScript numbers.
    struct TokenUsage {
        var input: Double?
        var output: Double?
        var total: Double?
    }

    /// What every agent's run shares: the prompt and the invocation's options.
    struct Job {
        var prompt: [ContentBlock]
        var flags: GlobalFlags
        var config: ResolvedAcpxConfig
        var permission: PermissionPolicy
        var permissionRules: PermissionRules?
        var mcpServers: [MCPServerSpec]

        /// acpx's `globalFlags.timeout ?? DEFAULT_COMPARE_TIMEOUT_MS`.
        var timeoutMs: Int { flags.timeoutMs ?? CompareCommand.defaultTimeoutMs }
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

        let promptFile = scan.string("file") ?? scan.string("prompt-file")
        let (agents, promptText) = try splitArgs(context.positionals, promptFile: promptFile)
        let prompt = try PromptInputResolver.contentBlocks(PromptInputResolver.resolve(
            words: promptText.isEmpty ? [] : [promptText], file: promptFile, cwd: flags.cwd))
        let job = Job(
            prompt: prompt, flags: flags, config: context.config,
            permission: try SessionLifecycle.permissionPolicy(flags, config: context.config),
            permissionRules: try flags.permissionRules(), mcpServers: try context.config.mcpServerSpecs())

        let (rows, interrupted) = runAgents(agents) { runAgent($0, job) }
        printRows(rows, format: format)
        if interrupted { return ExitCodes.interrupted }
        if rows.contains(where: { $0.status == "error" }) { return ExitCodes.error }
        if rows.contains(where: { $0.status == "permission_denied" }) { return ExitCodes.permissionDenied }
        if rows.contains(where: { $0.status == "cancelled" }) { return ExitCodes.timeout }
        return ExitCodes.success
    }

    /// acpx's `runCompareAgents`: each agent in turn, until a signal. The run a signal
    /// comes during ends as its interrupt makes it end, and its row says so; no agent
    /// after it runs.
    static func runAgents(_ agents: [String], _ run: (String) -> Row) -> (rows: [Row], interrupted: Bool) {
        let signal = Interrupts.Heard()
        let listening = Interrupts.listen { signal.heard() }
        defer { listening.stop() }
        var rows: [Row] = []
        for agentName in agents {
            if signal.happened { break }
            // One that comes from here on is the run's too, before it listens for its own.
            let row = Interrupts.$heardBefore.withValue(signal) { run(agentName) }
            rows.append(signal.happened ? row.interrupted : row)
        }
        return (rows, signal.happened)
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

    // MARK: Output

    private static func printRows(_ rows: [Row], format: String) {
        switch format {
        case "json":
            Console.out(WireJSON.array(rows.map(\.json)).stringified + "\n")
        case "quiet":
            for row in rows { Console.out("\(row.agent)\t\(row.status)\n") }
        default:
            Console.out(renderTable(rows) + "\n")
        }
    }

    /// acpx's `renderTable`: each column as wide as its widest cell, in JavaScript's
    /// string length — UTF-16 units.
    private static func renderTable(_ rows: [Row]) -> String {
        let headers = [
            "agent", "status", "wall_ms", "input", "output", "total", "permissions",
            "stop_reason", "final_message", "error"
        ]
        let body = rows.map { row -> [String] in
            [
                cell(row.agent), cell(row.status), cell(Double(row.wallMs)), cell(row.usage.input),
                cell(row.usage.output), cell(row.usage.total),
                cell("\(row.permissionDenied)/\(row.permissionRequests)"),
                cell(row.stopReason), cell(row.finalMessage), cell(row.error)
            ]
        }
        let widths = headers.indices.map { index in
            ([headers[index]] + body.map { $0[index] }).map(\.utf16.count).max() ?? 0
        }
        func formatRow(_ cells: [String]) -> String {
            zip(cells, widths).map { cell, width in
                let shown = truncate(cell, width)
                return shown + String(repeating: " ", count: max(0, width - shown.utf16.count))
            }.joined(separator: "  ").javaScriptTrimmedEnd
        }
        return ([formatRow(headers), widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")]
            + body.map(formatRow)).joined(separator: "\n")
    }

    /// acpx's `formatCell` for a string: `-` when missing or empty, else collapsed.
    private static func cell(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "-" }
        return value.javaScriptCollapsed
    }

    /// acpx's `formatCell` for a number: as JavaScript prints it, `-` when missing.
    private static func cell(_ value: Double?) -> String {
        value.map(WireJSON.javaScriptString(for:)) ?? "-"
    }

    /// acpx's `truncate`, in UTF-16 units: `...` in place of what goes past `maxChars`.
    static func truncate(_ value: String, _ maxChars: Int) -> String {
        let units = value.utf16
        guard units.count > maxChars else { return value }
        return String(decoding: Array(units.prefix(max(0, maxChars - 3))), as: UTF16.self) + "..."
    }
}

extension CompareCommand.Row {
    /// The row as acpx's `JSON.stringify` prints it: `null` where a value is missing, and
    /// `_meta` last, on a row that has one.
    var json: WireJSON {
        func number(_ value: Double?) -> WireJSON { value.map(WireJSON.number) ?? .null }
        var members: [WireJSON.Member] = [
            .init("agent", .text(agent)),
            .init("status", .text(status)),
            .init("stop_reason", stopReason.map(WireJSON.text) ?? .null),
            .init("wall_ms", .number(Double(wallMs))),
            .init("input_tokens", number(usage.input)),
            .init("output_tokens", number(usage.output)),
            .init("total_tokens", number(usage.total)),
            .init("final_message", .text(finalMessage)),
            .init("error", error.map(WireJSON.text) ?? .null),
            .init("permission_requests", .number(Double(permissionRequests))),
            .init("permission_denied", .number(Double(permissionDenied)))
        ]
        if let meta { members.append(.init("_meta", meta)) }
        return .object(members)
    }
}
