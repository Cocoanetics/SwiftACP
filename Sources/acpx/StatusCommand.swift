import ACPXCore
import Foundation
import JSONFoundation

/// `acpx [<agent>] status` — the status of the session for the current cwd: acpx's,
/// with acpxd asked whether it holds the session where acpx probes its queue owner.
enum StatusCommand {
    static func run(_ context: CommandContext) throws -> Int32 {
        let scan = context.options
        let flags = try context.globalFlags()
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try scan.parsed("session", parseSessionName)

        guard let record = SessionStore.findSession(
            agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, includeClosed: false)
        else {
            printMissing(agentCommand: agent.agentCommand, format: flags.format)
            return ExitCodes.success
        }
        let id = record.acpxRecordId
        let hold = (try? runBlocking { await DaemonClient.sessionHold(sessionId: id) }) ?? .unknown
        printStatus(record, hold: hold, format: flags.format)
        return ExitCodes.success
    }

    /// acpx's `resolveStatusState`: `running` while acpxd holds the session, `dead` when a
    /// daemon holds the lock and does not answer or the agent last exited badly, and
    /// `idle` otherwise.
    static func state(of record: SessionRecord, hold: DaemonClient.SessionHold) -> String {
        switch hold {
        case .held: return "running"
        case .unreachable: return "dead"
        case .notHeld, .unknown:
            let signalled = !(record.lastAgentExitSignal?.value ?? "").isEmpty
            return signalled || (record.lastAgentExitCode?.value ?? 0) != 0 ? "dead" : "idle"
        }
    }

    /// acpx's `formatUptime`: the time since `startedAt` as `HH:MM:SS` — as many hours as
    /// there are — or `nil` when there is no time to count from.
    static func uptime(since startedAt: String?, now: Date = Date()) -> String? {
        guard let startedAt, let started = startDate(startedAt) else { return nil }
        let seconds = Int(max(0, now.timeIntervalSince(started)).rounded(.down))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
    }

    private static func startDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
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

    /// The session's status as acpx prints it (`printSessionStatus`): the process that
    /// holds it and for how long only while it runs, how its agent exited only when dead.
    static func printStatus(
        _ record: SessionRecord, hold: DaemonClient.SessionHold, format: String, now: Date = Date()
    ) {
        let state = state(of: record, hold: hold)
        let pid: Int? = if case .held(let pid) = hold { pid } else { nil }
        let uptime = state == "running" ? uptime(since: record.agentStartedAt, now: now) : nil
        let model = record.acpx?.currentModelId
        let mode = record.acpx?.currentModeId

        switch format {
        case "json":
            var pairs: [(String, JSONValue)] = [
                ("action", .string("status_snapshot")),
                ("status", .string(state == "running" ? "alive" : state)),
                ("summary", .string(summary(state))),
                ("acpxRecordId", .string(record.acpxRecordId)),
                ("acpxSessionId", .string(record.acpSessionId))
            ]
            if let v = record.agentSessionId { pairs.append(("agentSessionId", .string(v))) }
            if let v = pid { pairs.append(("pid", .integer(v))) }
            if let v = model { pairs.append(("model", .string(v))) }
            if let v = mode { pairs.append(("mode", .string(v))) }
            if let v = record.acpx?.availableModels {
                pairs.append(("availableModels", .array(v.map(JSONValue.string))))
            }
            if let v = uptime { pairs.append(("uptime", .string(v))) }
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
                "pid: \(pid.map(String.init) ?? "-")",
                "status: \(state)",
                "model: \(model ?? "-")",
                "mode: \(mode ?? "-")",
                "uptime: \(uptime ?? "-")",
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
