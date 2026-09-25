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
    func set(_ ended: TurnEndedEvent) {
        value = StopReason(rawValue: ended.stopReason)
        permissions = ended.permissions
        usage = ended.usage
        cost = ended.cost
        unanswered = ended.unanswered ?? false
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

    /// A direct TCP endpoint for the running daemon, read from its lock file, or nil
    /// if no live daemon has recorded a port yet.
    static func liveEndpoint() -> MCPServerTcpConfig? {
        liveHolder().flatMap(endpoint)
    }

    /// The daemon holding the lock, while it still does (``DaemonLock/isHeld(_:)``).
    static func liveHolder() -> DaemonLock.Holder? {
        guard let holder = DaemonLock().currentHolder(), DaemonLock.isHeld(holder) else { return nil }
        return holder
    }

    /// Where `holder` listens, once it has recorded a port.
    static func endpoint(of holder: DaemonLock.Holder) -> MCPServerTcpConfig? {
        guard let port = holder.port, let tcpPort = UInt16(exactly: port) else { return nil }
        return MCPServerTcpConfig(host: "127.0.0.1", port: tcpPort)
    }

    /// Connect to the daemon and return a connected proxy. Finds it by the
    /// `127.0.0.1:port` recorded in its lock file — no Bonjour discovery. When
    /// `spawnIfNeeded` is true, launches `acpxd` and waits for it to record its port;
    /// otherwise throws if none is running. `configure` runs on the proxy before
    /// connecting (e.g. to install a log handler). Throws ``DaemonUnavailable``.
    ///
    /// - Parameter daemonExecutable: the `acpxd` to start; the one beside this CLI, or
    ///   on `PATH`, when `nil`.
    static func connect(
        spawnIfNeeded: Bool, daemonExecutable: String? = nil,
        configure: @Sendable (MCPServerProxy) async -> Void = { _ in }
    ) async throws -> MCPServerProxy {
        if let proxy = await tryConnectLive(configure: configure) {
            return proxy
        }
        guard spawnIfNeeded, standIn == nil else { throw DaemonUnavailable("no daemon is running") }
        let startup: DaemonStartup
        do {
            startup = try DaemonStartup.launch(daemonExecutable ?? daemonExecutablePath())
        } catch {
            // Couldn't even launch acpxd — retrying is pointless.
            throw DaemonUnavailable("launching acpxd failed: \(error.localizedDescription)")
        }
        // Once the daemon answers, what it writes is no longer kept.
        defer { startup.stopCapture() }
        // Wait for the freshly-spawned daemon to come up and record its port, as acpx
        // waits for its queue owner: one that ended unsuccessfully meanwhile failed to
        // start, and waiting on is pointless. One that lost the singleton race exits
        // cleanly, so we still resolve to the one running manager.
        for _ in 0 ..< 60 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let proxy = await tryConnect(liveEndpoint(), configure: configure) {
                return proxy
            }
            if startup.failed { throw DaemonUnavailable(startupFailure: startup.failureMessage) }
        }
        // What it said, if anything, says more than that it could not be reached.
        if startup.exit != nil || startup.wroteToStderr {
            throw DaemonUnavailable(startupFailure: startup.failureMessage)
        }
        throw DaemonUnavailable("it did not become reachable within ~9s of being started")
    }

    /// Try to connect to the running daemon: the stand-in, else the one the lock names.
    static func tryConnectLive(
        configure: @Sendable (MCPServerProxy) async -> Void
    ) async -> MCPServerProxy? {
        if let standIn { return await tryConnect(to: standIn, configure: configure) }
        return await tryConnect(liveEndpoint(), configure: configure)
    }

    /// Try to connect to `endpoint`; returns a connected proxy, or nil on any failure.
    static func tryConnect(
        _ endpoint: MCPServerTcpConfig?, configure: @Sendable (MCPServerProxy) async -> Void
    ) async -> MCPServerProxy? {
        guard let endpoint else { return nil }
        return await tryConnect(to: .tcp(config: endpoint), configure: configure)
    }

    private static func tryConnect(
        to config: MCPServerConfig, configure: @Sendable (MCPServerProxy) async -> Void
    ) async -> MCPServerProxy? {
        let proxy = MCPServerProxy(config: config)
        await configure(proxy)
        do {
            try await proxy.connect(clientName: "acpx", clientVersion: ACPVersion.current)
            return proxy
        } catch {
            await proxy.disconnect()
            return nil
        }
    }

    /// Run a prompt through the daemon. Returns the stop reason, or throws
    /// ``DaemonUnavailable`` if the daemon can't be reached or started (there is no
    /// fallback — the daemon is the single manager that owns the session).
    ///
    /// - Parameter wait: when `false` (`--no-wait`), the daemon rejects the turn
    ///   immediately if another turn is already running for the session, instead of
    ///   queueing behind it.
    ///
    /// The tool result is the agent's aggregate response text, which the CLI
    /// ignores (it streams the same output live via `renderer`). The stop reason
    /// arrives as a terminal ``TurnEndedEvent`` log notification, captured here.
    static func runPrompt(
        sessionId: String, content: [JSONValue], wait: Bool = true,
        permissionMode: String, nonInteractivePermissions: String, permissionPolicy: PermissionRules? = nil,
        terminalOutputCeiling: Int? = nil, model: String? = nil, limits: PromptLimits? = nil,
        renderer: OutputRenderer
    ) async throws -> DaemonTurn {
        let stopReason = StopReasonBox()
        let proxy = try await connect(spawnIfNeeded: true) { proxy in
            await proxy.setLogNotificationHandler(PromptLogRenderer(renderer, stopReason: stopReason))
        }
        defer { Task { await proxy.disconnect() } }
        return try await runPrompt(
            on: proxy, stopReason: stopReason, sessionId: sessionId, content: content, wait: wait,
            permissionMode: permissionMode, nonInteractivePermissions: nonInteractivePermissions,
            permissionPolicy: permissionPolicy, terminalOutputCeiling: terminalOutputCeiling, model: model,
            limits: limits, streamWire: renderer.streamsWireJSON)
    }

    /// The turn itself, on a connected proxy whose log notifications feed `stopReason`.
    static func runPrompt(
        on proxy: MCPServerProxy, stopReason: StopReasonBox, sessionId: String, content: [JSONValue],
        wait: Bool, permissionMode: String, nonInteractivePermissions: String,
        permissionPolicy: PermissionRules? = nil, terminalOutputCeiling: Int? = nil, model: String? = nil,
        limits: PromptLimits? = nil, streamWire: Bool = false
    ) async throws -> DaemonTurn {
        // The daemon reads the agent command + cwd from the session's record. The tool
        // result (the agent's aggregate text) is ignored — the CLI streams it live.
        // The permission mode travels with every turn, as acpx sends it with every
        // prompt: the daemon applies it to this turn only. So does the cap on terminal
        // output — `0` for none, so the daemon's own never stands in for it.
        do {
            _ = try await ACPXDaemon.Client(proxy: proxy).runPrompt(
                sessionId: sessionId, text: "", content: content, wait: wait,
                permissionMode: permissionMode, nonInteractivePermissions: nonInteractivePermissions,
                streamWire: streamWire, permissionPolicy: permissionPolicy,
                terminalOutputCeiling: terminalOutputCeiling ?? 0, model: model, limits: limits)
        } catch is DecodingError {
            // The turn succeeded; only its ignored text did not decode. SwiftMCP's typed
            // client turns a plain-text result into a JSON string by wrapping it in
            // quotes unescaped, so a reply holding a newline or a quote — nearly every
            // reply — fails there. A failed call arrives as `MCPServerProxyError`, not this.
        } catch {
            // Ordered delivery: the daemon's account of the failure came first.
            if let failure = await stopReason.failure { throw DaemonTurnFailed(event: failure, underlying: error) }
            throw error
        }
        // Ordered delivery means the terminal event was handled before the tool
        // result resumed this call; default defensively if it somehow wasn't.
        return DaemonTurn(
            stopReason: await stopReason.value ?? .endTurn, permissions: await stopReason.permissions,
            usage: await stopReason.usage, cost: await stopReason.cost, unanswered: await stopReason.unanswered)
    }

    /// A control the daemon ran for this CLI failed, for the reason in `message`.
    struct DaemonControlFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Set a session's mode on the live agent via the daemon (which persists it). What
    /// the agent asks meanwhile is answered as acpx's direct controls answer it —
    /// reads approved, the rest by `nonInteractivePermissions` — and the daemon caps
    /// terminal output by `terminalOutputCeiling`, as it does a turn's: `0` for none,
    /// so its own never stands in.
    static func setMode(
        sessionId: String, modeId: String, nonInteractivePermissions: String, terminalOutputCeiling: Int?,
        timeoutMs: Int?
    ) async throws -> SessionControlResult {
        try await timingOut(after: timeoutMs) {
            try await withClient {
                try await $0.setMode(
                    sessionId: sessionId, modeId: modeId, nonInteractivePermissions: nonInteractivePermissions,
                    terminalOutputCeiling: terminalOutputCeiling ?? 0, timeoutMs: timeoutMs)
            }
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
        timeoutMs: Int?
    ) async throws -> SessionControlResult {
        try await timingOut(after: timeoutMs) {
            try await withClient {
                try await $0.setModel(
                    sessionId: sessionId, modelId: modelId, nonInteractivePermissions: nonInteractivePermissions,
                    terminalOutputCeiling: terminalOutputCeiling ?? 0, timeoutMs: timeoutMs)
            }
        }
    }

    /// Set a session config option on the live agent via the daemon: the agent's
    /// advertised config options after the change, and whether the session had to be
    /// taken back first. It answers and caps as
    /// ``setMode(sessionId:modeId:nonInteractivePermissions:terminalOutputCeiling:timeoutMs:)``.
    static func setConfigOption(
        sessionId: String, configId: String, value: String, nonInteractivePermissions: String,
        terminalOutputCeiling: Int?, timeoutMs: Int?
    ) async throws -> SessionControlResult {
        try await timingOut(after: timeoutMs) {
            try await withClient {
                try await $0.setConfigOption(
                    sessionId: sessionId, configId: configId, value: value,
                    nonInteractivePermissions: nonInteractivePermissions,
                    terminalOutputCeiling: terminalOutputCeiling ?? 0, timeoutMs: timeoutMs)
            }
        }
    }

    /// A control the daemon ran under `timeoutMs`: one it failed as the timeout is the
    /// ``TimeoutError`` it was, which acpx reports as `TIMEOUT` (exit 3), with its hint.
    static func timingOut<T>(after timeoutMs: Int?, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as DaemonControlFailure {
            if let timeoutMs, timeoutMs > 0, failure.message == TimeoutError(milliseconds: timeoutMs).errorDescription {
                throw TimeoutError(milliseconds: timeoutMs)
            }
            throw failure
        }
    }

    /// Ask a *running* daemon to release its live agent for `sessionId` and mark the
    /// record closed. Returns whether a daemon handled it. Never spawns one — with no
    /// daemon there is no held connection, and the caller marks the record itself.
    ///
    /// This is what makes the remedy the MCP-config conflict suggests ("close the
    /// session before retrying") work from the CLI: only the daemon can drop the held
    /// connection that pins the session's MCP servers.
    static func closeSession(sessionId: String) async -> Bool {
        (try? await withClient(spawnIfNeeded: false) {
            try await $0.closeSession(sessionId: sessionId)
        }) ?? false
    }

    /// Ask a *running* daemon to cancel the in-flight prompt for `sessionId`.
    /// Returns whether a live turn was cancelled. Never spawns a daemon — if none
    /// is reachable (or the session isn't live) there is nothing to cancel. A daemon
    /// that could not send the cancel throws why.
    static func cancelSession(sessionId: String) async throws -> Bool {
        do {
            return try await withClient(spawnIfNeeded: false) {
                try await $0.cancelSession(sessionId: sessionId)
            }
        } catch is DaemonUnavailable {
            // acpx with no queue owner: nothing holds the turn.
            return false
        }
    }

    /// Connect to the daemon (spawning if needed) and run `body` with the generated,
    /// typed ``ACPXDaemon/Client`` proxy, disconnecting afterward.
    static func withClient<T>(
        spawnIfNeeded: Bool = true, _ body: (ACPXDaemon.Client) async throws -> T
    ) async throws -> T {
        let proxy = try await connect(spawnIfNeeded: spawnIfNeeded)
        defer { Task { await proxy.disconnect() } }
        do {
            return try await body(ACPXDaemon.Client(proxy: proxy))
        } catch {
            throw controlFailure(error)
        }
    }

    /// The daemon's own error, said as acpx says it — without the MCP client's `Tool
    /// call failed: `, since the control ran where acpx runs it, not in a tool.
    static func controlFailure(_ error: Error) -> Error {
        guard case MCPServerProxyError.toolError(let message) = error else { return error }
        return DaemonControlFailure(message: message)
    }

    private static func daemonExecutablePath() -> String {
        // Prefer `acpxd` sitting next to the *actually running* `acpx` binary.
        // `Bundle.main.executableURL` resolves the real install location even when
        // acpx was invoked as a bare name via PATH — where `CommandLine.arguments.first`
        // is just "acpx", which `URL(fileURLWithPath:)` would wrongly resolve against
        // the caller's cwd (so the daemon would never be found and silently not spawn).
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let sibling = exe.deletingLastPathComponent().appendingPathComponent("acpxd")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling.path
            }
        }
        // Otherwise fall back to the first `acpxd` found on PATH.
        if let onPath = executableOnPath("acpxd") {
            return onPath
        }
        // Last resort: the bare name (let the OS resolve it; may still fail).
        return "acpxd"
    }

    /// Search `PATH` for an executable file named `name`.
    private static func executableOnPath(_ name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        let fileManager = FileManager.default
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
