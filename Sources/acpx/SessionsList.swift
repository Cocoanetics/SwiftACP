import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// `sessions` and `sessions list`, as acpx 0.19.3's `handleSessionsList` runs them: the agent's
/// own sessions over `session/list` when it advertises `sessionCapabilities.list`, printed as it
/// answered — else, with `--local`, or when the agent cannot be spawned, the local records (#244).
enum SessionsList {
    static func run(_ context: CommandContext) throws -> Int32 {
        let scan = context.options
        let flags = try context.globalFlags()
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let cursor = scan.string("cursor")
        // acpx's `resolveSessionListFilterCwd`: resolved against the agent's working directory.
        let filterCwd = scan.string("filter-cwd").map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: agent.cwd)).standardizedFileURL.path
        }
        if scan.flag("local") {
            if cursor != nil { throw InvalidArgumentError("--cursor cannot be combined with --local") }
            printLocal(agent, filterCwd: filterCwd, format: flags.format)
            return ExitCodes.success
        }
        let permissions = try SessionLifecycle.resolvePermissions(flags, config: context.config)
        let outcome: Outcome
        do {
            outcome = try fetch(
                agent, cursor: cursor, filterCwd: filterCwd, flags: flags, config: context.config,
                permissions: permissions)
        } catch is InterruptedError {
            // acpx's top level ends an interrupted command `INTERRUPTED`, without a word.
            return ExitCodes.interrupted
        }
        switch outcome {
        case .listed(let result):
            try printAgentSessions(result, format: flags.format)
        case .unsupported where cursor != nil || filterCwd != nil:
            throw CLIError(
                "Agent command \"\(agent.agentCommand)\" does not advertise sessionCapabilities.list; "
                    + "cannot use agent-side session/list filters")
        case .unsupported, .spawnFailed:
            printLocal(agent, filterCwd: nil, format: flags.format)
        }
        return ExitCodes.success
    }

    /// The local records of `agent`, in `filterCwd` when given (acpx's `printLocalSessionsList`).
    private static func printLocal(_ agent: AgentInvocation, filterCwd: String?, format: String) {
        var records = SessionStore.listSessions(forAgent: agent.agentCommand)
        if let filterCwd { records = records.filter { $0.cwd == filterCwd } }
        SessionsCommand.printSessions(records, format: format)
    }

    /// What asking the agent came to.
    enum Outcome {
        /// Its answer, as acpx's `listAgentSessions` returns it (`AgentSessionListResult`).
        case listed(WireJSON)
        /// It does not advertise `sessionCapabilities.list`.
        case unsupported
        /// It could not be spawned (acpx's `AgentSpawnError`).
        case spawnFailed
    }

    /// acpx's `listAgentSessions`: the agent started within `--timeout` and, when it advertises
    /// `session/list`, asked for its sessions — in `filterCwd` and after `cursor`, when given —
    /// within `--timeout` too; closed before the listing is over, however it ends. A signal closes
    /// it — or calls off its launch, and closes one that came up then — and the run ends as
    /// whichever comes first, its own failure or the interrupt (acpx's `withInterrupt`): a request
    /// still out fails with the agent (``RunInterrupt/putDown(endInterrupted:)``).
    private static func fetch(
        _ agent: AgentInvocation, cursor: String?, filterCwd: String?, flags: GlobalFlags,
        config: ResolvedAcpxConfig, permissions: (policy: PermissionPolicy, rules: PermissionRules?)
    ) throws -> Outcome {
        let answer = ListAnswer()
        let interrupt = RunInterrupt()
        return try runBlocking {
            try await Interrupts.withInterrupt({
                let handle: ACPAgent
                do {
                    handle = try await interrupt.launch {
                        try await ExecCommand.launchAgent(within: flags.timeoutMs) {
                            try await ACPAgent.launch(
                                agent: agent.agentCommand, argv: agent.agentArgv, cwd: agent.cwd,
                                permission: permissions.policy, nonInteractivePermissions: flags.nonInteractivePolicy,
                                permissionRules: permissions.rules, capabilities: flags.clientCapabilities,
                                authCredentials: config.auth, authPolicy: flags.authPolicy,
                                inheritStderr: flags.verbose,
                                onRawWire: { answer.observe(inbound: $0 == .inbound, $1) }, onLog: flags.clientLog)
                        }
                    }
                } catch is AgentLaunchError {
                    return .spawnFailed
                }
                do {
                    let outcome = try await list(on: handle, cursor: cursor, filterCwd: filterCwd, answer: answer,
                                                 timeoutMs: flags.timeoutMs)
                    await handle.close()
                    return outcome
                } catch {
                    await handle.close()
                    throw error
                }
            }, onInterrupt: { await interrupt.putDown(endInterrupted: $0) })
        }
    }

    /// The agent's sessions, when it advertises `session/list`.
    private static func list(
        on handle: ACPAgent, cursor: String?, filterCwd: String?, answer: ListAnswer, timeoutMs: Int?
    ) async throws -> Outcome {
        guard truthy(handle.agentCapabilities?.sessionCapabilities?.list) else { return .unsupported }
        let connection = handle.connection
        let request = ListSessionsRequest(cwd: filterCwd, cursor: cursor)
        let decoded = try await withTimeout(milliseconds: timeoutMs) {
            try await connection.listSessions(request)
        }
        return .listed(result(answer.result ?? WireJSON(decoded), cursor: cursor, cwd: filterCwd))
    }

    /// `{_meta, source: "agent", sessions, cursor, cwd, nextCursor}` of the agent's answer, as
    /// `JSON.stringify` writes it: a member without a value left out.
    static func result(_ answer: WireJSON, cursor: String?, cwd: String?) -> WireJSON {
        let members: [(String, WireJSON?)] = [
            ("_meta", answer["_meta"]), ("source", .text("agent")), ("sessions", answer["sessions"]),
            ("cursor", cursor.map(WireJSON.text)), ("cwd", cwd.map(WireJSON.text)),
            ("nextCursor", answer["nextCursor"])
        ]
        return .object(members.compactMap { key, value in value.map { WireJSON.Member(key, $0) } })
    }

    /// Whether `value` is truthy in JavaScript, as acpx's `supportsListSessions` takes it.
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: return false
        case .bool(let flag)?: return flag
        case .integer(let number)?: return number != 0
        case .unsignedInteger(let number)?: return number != 0
        case .double(let number)?: return number != 0 && !number.isNaN
        case .string(let text)?: return !text.isEmpty
        case .array?, .object?: return true
        }
    }
}

/// The `result` of the agent's answer to `session/list`, as it wrote it: the response whose id
/// is the request's.
private final class ListAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var requestId: WireJSON?
    private var answer: WireJSON?

    var result: WireJSON? { lock.withLock { answer } }

    func observe(inbound: Bool, _ body: Data) {
        guard let parsed = WireJSON(parsing: body) else { return }
        let messages: [WireJSON] = if case .array(let items) = parsed { items } else { [parsed] }
        lock.withLock {
            for message in messages {
                if !inbound, message["method"]?.stringValue == "session/list" {
                    requestId = message["id"]
                } else if inbound, let requestId, message["id"] == requestId,
                    let result = message["result"] {
                    answer = result
                }
            }
        }
    }
}
