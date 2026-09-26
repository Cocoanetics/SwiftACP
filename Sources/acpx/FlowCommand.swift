import ACPXCore
import ACPXFlows
import Foundation
import SwiftACP

/// acpx's `flow run <file>` (`src/flows/cli.ts`, v0.19.3): a flow file run step by step,
/// its run bundle written under `~/.acpx/flows/runs/`. The flow's own code runs in a Node
/// host (``FlowHost``) — acpx runs it in its own Node process; the runner is Swift.
enum FlowCommand {
    static func run(_ context: CommandContext) throws -> Int32 {
        let flags = try context.globalFlags()
        let scan = context.options
        let permissionMode = try Flags.resolvePermissionMode(flags, default: context.config.defaultPermissions)
        let input = try readFlowInput(json: scan.string("input-json"), file: scan.string("input-file"))
        let flowPath = ACPXPaths.resolve(context.positionals.first ?? "", base: physicalCWD())
        let defaultAgent = scan.string("default-agent")
        return try runBlocking {
            let host = try FlowHost.start(
                node: try findNode(), cwd: physicalCWD(), environment: ProcessInfo.processInfo.environment)
            do {
                let flow = try FlowDescription(loaded: try await host.request(
                    "flow/load", .object([WireJSON.Member("path", .text(flowPath))])) ?? .null)
                try assertFlowPermissionRequirements(flow, mode: permissionMode, flags: flags)
                // acpx's runner resolves the default agent up front, for its working directory.
                let defaultCwd = try Flags.resolveAgentInvocation(defaultAgent, flags, config: context.config).cwd
                let options = FlowRunner.Options(defaultCwd: defaultCwd, timeoutMs: flags.timeoutMs.map(Double.init))
                let runner = FlowRunner(host: host, options: options)
                let result = try await Interrupts.withInterrupt({
                    try await runner.run(flow, input: input, flowPath: flowPath)
                }, onInterrupt: { endInterrupted in
                    endInterrupted()
                    await runner.interrupt()
                })
                // The flow ended the host after its last answer — a timer's `process.exit()`
                // — which in acpx ends the process before the result is printed.
                if host.exitedOnItsOwn { return FlowHost.exitCode(waitStatus: await host.stop()) }
                printFlowRunResult(result, format: flags.format)
                // acpx then ends once the flow's own timers and handles have run out, with
                // the code they leave; it exits at once only on failure.
                return FlowHost.exitCode(waitStatus: await host.release())
            } catch is FlowHost.Exited {
                // The flow's own code ended the host — `process.exit()`, a crash — and in acpx
                // that is acpx's process: it ends as the host did, printing nothing more.
                return FlowHost.exitCode(waitStatus: await host.stop())
            } catch is InterruptedError {
                await host.stop()
                return ExitCodes.interrupted
            } catch {
                let status = await host.stop()
                if host.exitedOnItsOwn { return FlowHost.exitCode(waitStatus: status) }
                throw error
            }
        }
    }

    /// acpx's `readFlowInput`: `--input-json`, the file `--input-file` names, or `{}`.
    static func readFlowInput(json: String?, file: String?) throws -> WireJSON {
        if json != nil, file != nil {
            throw InvalidArgumentError("Use only one of --input-json or --input-file")
        }
        if let json { return try parseJsonInput(json, label: "--input-json") }
        if let file {
            let path = ACPXPaths.resolve(file, base: physicalCWD())
            let payload = try String(contentsOfFile: path, encoding: .utf8)
            return try parseJsonInput(payload, label: "--input-file")
        }
        return .object([WireJSON.Member]())
    }

    private static func parseJsonInput(_ raw: String, label: String) throws -> WireJSON {
        do {
            return try WireJSON.parse(raw)
        } catch let error as WireJSON.SyntaxError {
            throw InvalidArgumentError("\(label) must contain valid JSON: \(error.message)")
        }
    }

    /// acpx's `assertFlowPermissionRequirements`: a flow that needs a permission mode is
    /// refused below it, and — asking for an explicit grant — without the flag for one.
    static func assertFlowPermissionRequirements(
        _ flow: FlowDescription, mode: String, flags: GlobalFlags
    ) throws {
        guard let permissions = flow.permissions else { return }
        let explicit = flags.approveAll || flags.approveReads || flags.denyAll
        if permissions.requireExplicitGrant, !explicit {
            throw InvalidArgumentError(permissionFailure(flow, permissions, explicit: true))
        }
        let rank = ["deny-all": 0, "approve-reads": 1, "approve-all": 2]
        if (rank[mode] ?? 0) < (rank[permissions.requiredMode] ?? 0) {
            throw InvalidArgumentError(permissionFailure(flow, permissions, explicit: false))
        }
    }

    /// acpx's `buildFlowPermissionFailureMessage`.
    private static func permissionFailure(
        _ flow: FlowDescription, _ permissions: FlowPermissionRequirements, explicit: Bool
    ) -> String {
        var parts = [
            explicit
                ? "Flow \"\(flow.name)\" requires an explicit \(permissions.requiredMode) grant."
                : "Flow \"\(flow.name)\" requires permission mode \(permissions.requiredMode).",
            "Rerun with --\(permissions.requiredMode)."
        ]
        if let reason = permissions.reason, !reason.isEmpty { parts.append("Reason: \(reason)") }
        return parts.joined(separator: " ")
    }

    /// acpx's `printFlowRunResult`.
    static func printFlowRunResult(_ result: FlowRunner.RunResult, format: String) {
        let state = result.state
        let payload: WireJSON = .object([
            ("action", .text("flow_run_result")), ("runId", state["runId"]), ("flowName", state["flowName"]),
            ("runTitle", state["runTitle"]), ("flowPath", state["flowPath"]), ("status", state["status"]),
            ("currentNode", state["currentNode"]), ("currentNodeType", state["currentNodeType"]),
            ("currentNodeStartedAt", state["currentNodeStartedAt"]), ("lastHeartbeatAt", state["lastHeartbeatAt"]),
            ("statusDetail", state["statusDetail"]), ("waitingOn", state["waitingOn"]),
            ("runDir", .text(result.runDir.path)), ("outputs", state["outputs"]),
            ("sessionBindings", state["sessionBindings"])
        ].compactMap { key, value in value.map { WireJSON.Member(key, $0) } })
        switch format {
        case "json":
            Console.out(payload.stringified + "\n")
        case "quiet":
            Console.out((state["runId"]?.stringValue ?? "") + "\n")
        default:
            var lines = ["runId: \(text(payload["runId"]))", "flow: \(text(payload["flowName"]))"]
            if truthy(payload["runTitle"]) { lines.append("title: \(text(payload["runTitle"]))") }
            lines.append("status: \(text(payload["status"]))")
            lines.append("runDir: \(result.runDir.path)")
            if truthy(payload["currentNode"]) { lines.append("currentNode: \(text(payload["currentNode"]))") }
            if truthy(payload["statusDetail"]) { lines.append("statusDetail: \(text(payload["statusDetail"]))") }
            if truthy(payload["waitingOn"]) { lines.append("waitingOn: \(text(payload["waitingOn"]))") }
            lines.append((payload["outputs"] ?? .object([WireJSON.Member]())).stringified(indent: 2))
            Console.out(lines.map { $0 + "\n" }.joined())
        }
    }

    /// `${value}`: how a template literal writes a member.
    private static func text(_ value: WireJSON?) -> String {
        guard let value else { return "undefined" }
        if let string = value.stringValue { return string }
        if case .number(let number) = value { return WireJSON.javaScriptString(for: number) }
        return value.stringified
    }

    /// Whether JavaScript reads a member as true.
    private static func truthy(_ value: WireJSON?) -> Bool {
        switch value {
        case nil, .null?: return false
        case .bool(let flag)?: return flag
        case .number(let number)?: return number != 0 && !number.isNaN
        case .string(let units)?: return !units.isEmpty
        default: return true
        }
    }

    /// Node, from `PATH`: the runtime acpx itself needs (22.13 or later).
    private static func findNode() throws -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/node"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw FlowNodeMissing()
    }
}

/// No Node to run the flow's code with.
struct FlowNodeMissing: Error, LocalizedError {
    var errorDescription: String? {
        "flow run needs Node.js (22.13 or later) on PATH to run the flow's code"
    }
}
