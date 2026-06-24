import ACPXCore
import Foundation
import JSONFoundation

/// `acpx [<agent>] status` — local status of the session for the current cwd.
enum StatusCommand {
    static func run(_ context: CommandContext) throws -> Int32 {
        let scan = try context.scan([OptionSpec("session", short: "s", takesValue: true)])
        let flags = try context.globalFlags(scan)
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.string("session").map(parseSessionName)

        guard let record = SessionStore.findSession(
            agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, includeClosed: false)
        else {
            printMissing(agentCommand: agent.agentCommand, format: flags.format)
            return ExitCodes.success
        }
        printStatus(record, format: flags.format)
        return ExitCodes.success
    }

    private static func printMissing(agentCommand: String, format: String) {
        switch format {
        case "json":
            Console.out(jsonObject([
                ("action", .string("status_snapshot")),
                ("status", .string("no-session")),
                ("summary", .string("no active session"))
            ]).compact() + "\n")
        case "quiet":
            Console.out("no-session\n")
        default:
            Console.out("""
                session: -
                agent: \(agentCommand)
                pid: -
                status: no-session
                model: -
                mode: -
                uptime: -
                lastPromptTime: -

                """)
        }
    }

    private static func printStatus(_ record: SessionRecord, format: String) {
        // No live daemon → never "running"; idle unless the agent exited abnormally.
        let abnormal = record.lastAgentExitSignal?.value != nil
            || (record.lastAgentExitCode?.value ?? 0) != 0
        let state = abnormal ? "dead" : "idle"
        let model = record.acpx?.currentModelId
        let mode = record.acpx?.currentModeId

        switch format {
        case "json":
            var pairs: [(String, JSONValue)] = [
                ("action", .string("status_snapshot")),
                ("status", .string(state)),
                ("summary", .string(summary(state))),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId))
            ]
            if let v = record.agentSessionId { pairs.append(("agentSessionId", .string(v))) }
            if let v = model { pairs.append(("model", .string(v))) }
            if let v = mode { pairs.append(("mode", .string(v))) }
            if let v = record.acpx?.availableModels {
                pairs.append(("availableModels", .array(v.map(JSONValue.string))))
            }
            if let v = record.lastPromptAt { pairs.append(("lastPromptTime", .string(v))) }
            if state == "dead" {
                if let v = record.lastAgentExitCode?.value { pairs.append(("exitCode", .integer(v))) }
                if let v = record.lastAgentExitSignal?.value { pairs.append(("signal", .string(v))) }
            }
            Console.out(jsonObject(pairs).compact() + "\n")
        case "quiet":
            Console.out("\(state)\n")
        default:
            var lines = ["session: \(record.acpxRecordId)"]
            if let v = record.agentSessionId { lines.append("agentSessionId: \(v)") }
            lines += [
                "agent: \(record.agentCommand)",
                "pid: -",
                "status: \(state)",
                "model: \(model ?? "-")",
                "mode: \(mode ?? "-")",
                "uptime: -",
                "lastPromptTime: \(record.lastPromptAt ?? "-")"
            ]
            if state == "dead" {
                lines.append("exitCode: \(record.lastAgentExitCode?.value.map(String.init) ?? "-")")
                lines.append("signal: \(record.lastAgentExitSignal?.value ?? "-")")
            }
            Console.out(lines.joined(separator: "\n") + "\n")
        }
    }

    private static func summary(_ state: String) -> String {
        switch state {
        case "running": return "queue owner healthy"
        case "idle": return "session idle; queue owner will start on next prompt"
        default: return "queue owner unavailable"
        }
    }
}
