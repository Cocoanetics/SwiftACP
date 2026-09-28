import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP

/// Holds the turn's stop reason, captured from the daemon's terminal
/// ``TurnEndedEvent`` log notification. Ordering on the wire (the event is sent
/// before `runPrompt` returns) guarantees it's set by the time the tool result
/// arrives.
actor StopReasonBox {
    private(set) var value: StopReason?
    /// How the turn's permissions went, when the daemon reported it.
    private(set) var permissions: PermissionStats?
    /// How the turn failed, when the daemon said (``TurnFailedEvent``).
    private(set) var failure: TurnFailedEvent?
    /// The prompt response's `usage` and `cost`, as the agent sent them.
    private(set) var usage: JSONValue?
    private(set) var cost: JSONValue?
    /// Whether the turn ended with no answer to its prompt (``TurnEndedEvent/unanswered``).
    private(set) var unanswered = false
    /// Why the session could not be taken back, when a new one replaced it (``TurnEndedEvent/loadError``).
    private(set) var loadError: String?
    /// Whether the turn's end came: its outcome, as acpx's CLI has it in the owner's `result`.
    private(set) var ended = false
    func set(_ ended: TurnEndedEvent) {
        self.ended = true
        value = StopReason(rawValue: ended.stopReason)
        permissions = ended.permissions
        usage = ended.usage
        cost = ended.cost
        unanswered = ended.unanswered ?? false
        loadError = ended.loadError
    }

    func fail(_ event: TurnFailedEvent) {
        failure = event
    }
}

/// A turn that failed the way the daemon described (``TurnFailedEvent``): the CLI
/// reports the event as acpx's formatters report such a failure.
struct DaemonTurnFailed: Error {
    let event: TurnFailedEvent
    let underlying: Error
}

/// What a daemon turn ended with: its stop reason, and how its permissions went —
/// which decides the exit code, as for `exec`.
struct DaemonTurn {
    var stopReason: StopReason
    var permissions: PermissionStats?
    /// The prompt response's `usage` and `cost`, for quiet output.
    var usage: JSONValue?
    var cost: JSONValue?
    /// No answer to the prompt came, so nothing marks the turn done.
    var unanswered = false
    /// The pid of the acpxd that ran the turn (``DaemonClient/ConnectedDaemon``).
    var ownerPid: Int32?
    /// Why the session could not be taken back, when a new one replaced it (``TurnEndedEvent/loadError``).
    var loadError: String?
}

/// Renders streamed session updates that arrive from the daemon as MCP log
/// notifications (the `acpxd` → CLI channel), and captures the turn's stop
/// reason from the terminal ``TurnEndedEvent``.
final class PromptLogRenderer: MCPServerProxyLogNotificationHandling, @unchecked Sendable {
    private let renderer: OutputRenderer
    private let stopReason: StopReasonBox
    init(_ renderer: OutputRenderer, stopReason: StopReasonBox) {
        self.renderer = renderer
        self.stopReason = stopReason
    }

    func mcpServerProxy(_ proxy: MCPServerProxy, didReceiveLog message: LogMessage) async {
        // A message as it crossed the agent's wire: what connecting the agent for the
        // turn sent and got back, and — asked for in JSON mode — the whole turn.
        if let wire = try? message.data.decoded(WireMessageEvent.self) {
            renderer.wireMessage(wire)
            return
        }
        // How the turn failed: reported once the call fails (see `DaemonTurnFailed`).
        if let failed = try? message.data.decoded(TurnFailedEvent.self) {
            await stopReason.fail(failed)
            return
        }
        // The prompt's answer: acpx's formatters mark the turn done there, and render
        // what the agent sends after it as it comes — quiet output none of its text.
        if let answered = try? message.data.decoded(TurnAnsweredEvent.self) {
            renderer.finish(stopReason: StopReason(rawValue: answered.answeredStopReason) ?? .endTurn)
            return
        }
        // The turn's end: how it went, its permissions read once it was over. Marked done
        // here when there was no answer to mark it at — or no daemon that announces one.
        if let ended = try? message.data.decoded(TurnEndedEvent.self) {
            await stopReason.set(ended)
            renderer.finish(
                stopReason: StopReason(rawValue: ended.stopReason) ?? .endTurn, answered: ended.unanswered != true)
            return
        }
        // A request the agent made of the daemon's client, or its refusal — acpx
        // prints both. Checked before `ClientOperation`, whose shape it does not share.
        if let request = try? message.data.decoded(InboundRequest.self) {
            renderer.inboundRequest(request)
            return
        }
        // A client-side operation the daemon's connection reported mid-turn (a
        // permission refusal that may end the turn), streamed in order with updates.
        if let operation = try? message.data.decoded(ClientOperation.self) {
            renderer.clientOperation(operation)
            return
        }
        guard let note = try? message.data.decoded(SessionNotification.self) else { return }
        renderer.render(note.update)
    }
}

/// Thrown when the daemon can't be reached and a freshly spawned one didn't come
/// up in time. There is no direct fallback — `acpxd` is the single manager that
/// owns the live agent sessions and their persisted history — so the CLI surfaces
/// ``cliMessage`` and aborts the request.
struct DaemonUnavailable: Error {
    /// Why the daemon couldn't be reached (a spawn-launch failure, or a timeout),
    /// woven into the user-facing CLI error.
    let detail: String?
    /// Why the acpxd this CLI started ended before it could be reached, in acpx's words
    /// for its queue owner (``DaemonStartup/failureMessage``): the whole message then.
    let startupFailure: String?
    init(_ detail: String? = nil) {
        self.detail = detail
        startupFailure = nil
    }

    init(startupFailure: String) {
        detail = nil
        self.startupFailure = startupFailure
    }

    /// Actionable, user-facing message for the CLI's error output.
    var cliMessage: String {
        if let startupFailure { return startupFailure }
        var message = "could not reach the acpxd daemon"
        if let detail { message += " (\(detail))" }
        return message
            + "; the request was not run. acpxd owns the live agent sessions and their"
            + " history, so acpx routes every prompt and control command through it. Make"
            + " sure the 'acpxd' binary is installed next to 'acpx' (or on PATH) and that"
            + " local network access is allowed, then retry."
    }
}

/// Drives the `acpxd` MCP daemon: connect to it by the `127.0.0.1` port it records
/// in its lock file (spawning it if needed), call its tools, render streamed updates.
enum DaemonClient {
    /// The daemon a run under test talks to, in place of the one the lock names: one in
    /// process, say. None is started in its place.
    @TaskLocal static var standIn: MCPServerConfig?

    /// Run a prompt through the daemon. Returns the stop reason, or throws
    /// ``DaemonUnavailable`` if the daemon can't be reached or started (there is no
    /// fallback — the daemon is the single manager that owns the session).
    ///
    /// - Parameter wait: when `false` (`--no-wait`), the call returns once the session's
    ///   line has the prompt, which then runs on in the daemon, its output going to no one.
    ///
    /// The tool result is the agent's aggregate response text, which the CLI
    /// ignores (it streams the same output live via `renderer`). The stop reason
    /// arrives as a terminal ``TurnEndedEvent`` log notification, captured here.
    ///
    /// The turn carries this CLI's environment: a session no owner holds gets one started
    /// over it, as acpx's CLI spawns a session's queue owner with its own (#222) — and with
    /// `client`, the `--no-fs`, `--no-terminal` and `--auth-policy` it builds its client with (#246).
    static func runPrompt(
        sessionId: String, content: [JSONValue], wait: Bool = true,
        permissionMode: String, nonInteractivePermissions: String, permissionPolicy: PermissionRules? = nil,
        terminalOutputCeiling: Int? = nil, model: String? = nil, sessionOptions: PromptSessionOptions? = nil,
        limits: PromptLimits? = nil, client: ClientOptions = ClientOptions(), renderer: OutputRenderer,
        requestId: String? = nil
    ) async throws -> DaemonTurn {
        let stopReason = StopReasonBox()
        let daemon = try await connectToDaemon(spawnIfNeeded: true) { proxy in
            await proxy.setLogNotificationHandler(PromptLogRenderer(renderer, stopReason: stopReason))
        }
        let proxy = daemon.proxy
        defer { Task { await proxy.disconnect() } }
        var turn = try await runPrompt(
            on: proxy, stopReason: stopReason, sessionId: sessionId, content: content, wait: wait,
            permissionMode: permissionMode, nonInteractivePermissions: nonInteractivePermissions,
            permissionPolicy: permissionPolicy, terminalOutputCeiling: terminalOutputCeiling, model: model,
            sessionOptions: sessionOptions, limits: limits, mode: PromptTurnMode(
                streamWire: renderer.streamsWireJSON, fs: client.fs, terminal: client.terminal,
                authPolicy: client.authPolicy, environment: ProcessInfo.processInfo.environment,
                requestId: requestId))
        turn.ownerPid = daemon.pid
        return turn
    }

    /// The turn itself, on a connected proxy whose log notifications feed `stopReason`, run
    /// as `mode` says (``PromptTurnMode``).
    static func runPrompt(
        on proxy: MCPServerProxy, stopReason: StopReasonBox, sessionId: String, content: [JSONValue],
        wait: Bool, permissionMode: String, nonInteractivePermissions: String,
        permissionPolicy: PermissionRules? = nil, terminalOutputCeiling: Int? = nil, model: String? = nil,
        sessionOptions: PromptSessionOptions? = nil, limits: PromptLimits? = nil,
        mode: PromptTurnMode = PromptTurnMode()
    ) async throws -> DaemonTurn {
        // The daemon reads the agent command + cwd from the session's record. The tool
        // result (the agent's aggregate text) is ignored — the CLI streams it live.
        // The permission mode travels with every turn, as acpx sends it with every
        // prompt: the daemon applies it to this turn only. So does the cap on terminal
        // output — `0` for none, so the daemon's own never stands in for it.
        //
        // The tool is called untyped, so that text is never read: SwiftMCP's typed client
        // can fail to read it — a reply with a newline or a quote, nearly every reply — and
        // can crash on it: a reply that is one JSON object with a single scalar member
        // (`{"a":1}`) takes it to `JSONSerialization` with a top level no JSON writer takes,
        // an exception nothing catches. A failed call still arrives as `MCPServerProxyError`.
        do {
            _ = try await proxy.callToolResult("runPrompt", arguments: try promptArguments(
                sessionId: sessionId, content: content, wait: wait, permissionMode: permissionMode,
                nonInteractivePermissions: nonInteractivePermissions, permissionPolicy: permissionPolicy,
                terminalOutputCeiling: terminalOutputCeiling ?? 0, model: model, sessionOptions: sessionOptions,
                limits: limits, mode: mode))
        } catch {
            // Ordered delivery: the daemon's account of the failure came first.
            if let failure = await stopReason.failure { throw DaemonTurnFailed(event: failure, underlying: error) }
            // A daemon gone with the turn leaves its outcome unknown — unless the turn's end
            // came first, which is its outcome.
            guard (error as? JSONRPCPeerError) == .closed else { throw error }
            guard await stopReason.ended else { throw OwnerDisconnected(waitingFor: "prompt completion") }
        }
        // Ordered delivery means the terminal event was handled before the tool
        // result resumed this call; default defensively if it somehow wasn't.
        return DaemonTurn(
            stopReason: await stopReason.value ?? .endTurn, permissions: await stopReason.permissions,
            usage: await stopReason.usage, cost: await stopReason.cost, unanswered: await stopReason.unanswered,
            loadError: await stopReason.loadError)
    }

    /// Set a session's mode on the live agent via the daemon (which persists it). What
    /// the agent asks meanwhile is answered as acpx's direct controls answer it —
    /// reads approved, the rest by `nonInteractivePermissions` — and the daemon caps
    /// terminal output by `terminalOutputCeiling`, as it does a turn's: `0` for none,
    /// so its own never stands in. An agent the daemon starts for it starts over this CLI's
    /// environment, as acpx's direct control starts its client in the CLI's process (#222).
    ///
    /// `client` is what an agent it starts for a session no owner holds is built with, as acpx
    /// builds its direct control's client from the control's own flags (#246).
    static func setMode(
        sessionId: String, modeId: String, nonInteractivePermissions: String, terminalOutputCeiling: Int?,
        timeoutMs: Int?, verbose: Bool = false, client: ClientOptions = ClientOptions()
    ) async throws -> SessionControlResult {
        try await withClient(logs: verbose ? AgentStderrLog() : nil) {
            try await $0.setMode(
                sessionId: sessionId, modeId: modeId, nonInteractivePermissions: nonInteractivePermissions,
                terminalOutputCeiling: terminalOutputCeiling ?? 0, timeoutMs: timeoutMs,
                environment: ProcessInfo.processInfo.environment, verbose: verbose, fs: client.fs,
                terminal: client.terminal, authPolicy: client.authPolicy)
        }
    }

    /// Replace a session's own MCP servers via a *running* daemon (which persists them
    /// and sends them on the next reconnect), reconnecting a live session so the new
    /// servers take effect without losing it. Throws ``DaemonUnavailable`` when no
    /// daemon is running — then nothing holds the session, and the caller persists the
    /// set itself.
    static func setSessionMcpServers(
        sessionId: String, mcpServers: [McpServerConfig], restart: Bool
    ) async throws {
        try await withClient(spawnIfNeeded: false) {
            _ = try await $0.setSessionMcpServers(
                sessionId: sessionId, mcpServers: mcpServers, restart: restart)
        }
    }

    /// Set a session's model on the live agent via the daemon (legacy set_model),
    /// answering and capping as ``setMode(sessionId:modeId:nonInteractivePermissions:terminalOutputCeiling:timeoutMs:)``.
    static func setModel(
        sessionId: String, modelId: String, nonInteractivePermissions: String, terminalOutputCeiling: Int?,
        timeoutMs: Int?, verbose: Bool = false, client: ClientOptions = ClientOptions()
    ) async throws -> SessionControlResult {
        try await withClient(logs: verbose ? AgentStderrLog() : nil) {
            try await $0.setModel(
                sessionId: sessionId, modelId: modelId, nonInteractivePermissions: nonInteractivePermissions,
                terminalOutputCeiling: terminalOutputCeiling ?? 0, timeoutMs: timeoutMs,
                environment: ProcessInfo.processInfo.environment, verbose: verbose, fs: client.fs,
                terminal: client.terminal, authPolicy: client.authPolicy)
        }
    }

    /// Set a session config option on the live agent via the daemon: the agent's
    /// advertised config options after the change, and whether the session had to be
    /// taken back first. It answers and caps as
    /// ``setMode(sessionId:modeId:nonInteractivePermissions:terminalOutputCeiling:timeoutMs:)``.
    static func setConfigOption(
        sessionId: String, configId: String, value: String, nonInteractivePermissions: String,
        terminalOutputCeiling: Int?, timeoutMs: Int?, verbose: Bool = false, client: ClientOptions = ClientOptions()
    ) async throws -> SessionControlResult {
        try await withClient(logs: verbose ? AgentStderrLog() : nil) {
            try await $0.setConfigOption(
                sessionId: sessionId, configId: configId, value: value,
                nonInteractivePermissions: nonInteractivePermissions,
                terminalOutputCeiling: terminalOutputCeiling ?? 0, timeoutMs: timeoutMs,
                environment: ProcessInfo.processInfo.environment, verbose: verbose, fs: client.fs,
                terminal: client.terminal, authPolicy: client.authPolicy)
        }
    }

    /// Under `--verbose`, acpx's line for a prompt or a control whose session had to start over:
    /// it could not be taken back, and a new session replaced it — `loadError` says why.
    static func noteFallback(_ loadError: String?, verbose: Bool) {
        guard verbose, let loadError else { return }
        Console.errLine("[acpx] session reconnect failed, started fresh session: \(loadError)")
    }

    /// Ask a *running* daemon to release its live agent for `sessionId` and mark the
    /// record closed. Returns whether a daemon handled it. Never spawns one — with no
    /// daemon there is no held connection, and the caller marks the record itself.
    ///
    /// This is what makes the remedy the MCP-config conflict suggests ("close the
    /// session before retrying") work from the CLI: only the daemon can drop the held
    /// connection that pins the session's MCP servers.
    ///
    /// A daemon of another version is refused (#162): it would still hold the agent the
    /// record, marked closed here, no longer names.
    static func closeSession(sessionId: String) async throws -> Bool {
        do {
            return try await withClient(spawnIfNeeded: false) { try await $0.closeSession(sessionId: sessionId) }
        } catch let mismatch as DaemonVersionMismatch {
            throw mismatch
        } catch {
            return false
        }
    }

    /// Ask a *running* daemon to cancel the in-flight prompt for `sessionId`.
    /// Returns whether a live turn was cancelled, and acpxd's pid if the session's owner took
    /// the cancel. Never spawns a daemon — if none is reachable (or the session isn't live)
    /// there is nothing to cancel. A daemon that could not send the cancel throws why.
    static func cancelSession(sessionId: String, turnToken: String? = nil) async throws -> SessionCancelResult {
        do {
            return try await withClient(spawnIfNeeded: false) {
                try await $0.cancelSession(sessionId: sessionId, turnToken: turnToken)
            }
        } catch is DaemonUnavailable {
            // acpx with no queue owner: nothing holds the turn.
            return SessionCancelResult(cancelled: false)
        }
    }

    /// Connect to the daemon (spawning if needed) and run `body` with the generated,
    /// typed ``ACPXDaemon/Client`` proxy, disconnecting afterward.
    static func withClient<T>(
        spawnIfNeeded: Bool = true, logs: MCPServerProxyLogNotificationHandling? = nil,
        _ body: (ACPXDaemon.Client) async throws -> T
    ) async throws -> T {
        let proxy = try await connect(spawnIfNeeded: spawnIfNeeded)
        defer { Task { await proxy.disconnect() } }
        if let logs { await proxy.setLogNotificationHandler(logs) }
        do {
            return try await body(ACPXDaemon.Client(proxy: proxy))
        } catch {
            throw controlFailure(error)
        }
    }

    /// The daemon's own error, said as acpx says it — without the MCP client's `Tool
    /// call failed: `, since the control ran where acpx runs it, not in a tool — and with
    /// what the daemon said of it beyond its message (``ToolFailure``). A daemon that went
    /// away with the control is acpx's owner that did.
    static func controlFailure(_ error: Error) -> Error {
        if (error as? JSONRPCPeerError) == .closed { return OwnerDisconnected(waitingFor: "responding") }
        switch error {
        case MCPServerProxyError.toolError(let message):
            return DaemonControlFailure(message: message)
        case MCPServerProxyError.toolErrorWithMeta(let message, let meta):
            return DaemonControlFailure(message: message, failure: ToolFailure(meta: meta))
        default:
            return error
        }
    }
}
