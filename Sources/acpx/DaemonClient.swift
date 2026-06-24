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
    func set(_ reason: StopReason) { value = reason }
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
        // The terminal event carries the stop reason, not a renderable update.
        if let ended = try? message.data.decoded(TurnEndedEvent.self) {
            await stopReason.set(StopReason(rawValue: ended.stopReason))
            return
        }
        guard let note = try? message.data.decoded(SessionNotification.self) else { return }
        renderer.render(note.update)
    }
}

/// Drives the `acpxd` MCP daemon: discover it via Bonjour (spawning it if
/// needed), call the `runPrompt` tool, and render the streamed updates.
/// Thrown when the daemon can't be reached (caller falls back to direct spawn).
struct DaemonUnavailable: Error {}

enum DaemonClient {
    static let serviceName = "acpx"

    /// Run a prompt through the daemon. Returns the stop reason, or throws if the
    /// daemon can't be reached (the caller falls back to a direct spawn).
    ///
    /// The tool result is the agent's aggregate response text, which the CLI
    /// ignores (it streams the same output live via `renderer`). The stop reason
    /// arrives as a terminal ``TurnEndedEvent`` log notification, captured here.
    static func runPrompt(
        sessionId: String, text: String, renderer: OutputRenderer
    ) async throws -> StopReason {
        let proxy = MCPServerProxy(config: .tcp(config: MCPServerTcpConfig(serviceName: serviceName)))
        let stopReason = StopReasonBox()
        await proxy.setLogNotificationHandler(PromptLogRenderer(renderer, stopReason: stopReason))

        try await connectOrSpawn(proxy)
        defer { Task { await proxy.disconnect() } }

        // The daemon reads the agent command + cwd from the session's record.
        _ = try await proxy.callTool("runPrompt", arguments: [
            "sessionId": .string(sessionId),
            "text": .string(text)
        ])
        // Ordered delivery means the terminal event was handled before the tool
        // result resumed this call; default defensively if it somehow wasn't.
        return await stopReason.value ?? .endTurn
    }

    /// Ask a *running* daemon to cancel the in-flight prompt for `sessionId`.
    /// Returns whether a live turn was cancelled. Never spawns a daemon — if none
    /// is reachable (or the session isn't live) there is nothing to cancel.
    static func cancelSession(sessionId: String) async -> Bool {
        let proxy = MCPServerProxy(config: .tcp(config: MCPServerTcpConfig(serviceName: serviceName)))
        do {
            try await proxy.connect(clientName: "acpx", clientVersion: ACPVersion.current)
        } catch {
            return false
        }
        defer { Task { await proxy.disconnect() } }
        guard let result = try? await proxy.callTool(
            "cancelSession", arguments: ["sessionId": .string(sessionId)]) else {
            return false
        }
        // The tool returns a Bool, rendered into the result's text payload.
        return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("true")
    }

    private static func connectOrSpawn(_ proxy: MCPServerProxy) async throws {
        do {
            try await proxy.connect(clientName: "acpx", clientVersion: ACPVersion.current)
            return
        } catch {
            spawnDaemon()
        }
        // Retry while the freshly-spawned daemon comes up + advertises.
        for _ in 0 ..< 40 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            do {
                try await proxy.connect(clientName: "acpx", clientVersion: ACPVersion.current)
                return
            } catch {}
        }
        throw DaemonUnavailable()
    }

    static func spawnDaemon() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonExecutablePath())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Detach into its own session so it survives this CLI process exiting.
        process.environment = ProcessInfo.processInfo.environment
        try? process.run()
        process.qualityOfService = .utility
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
