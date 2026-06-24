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
        let acpxPath = CommandLine.arguments.first ?? "acpx"
        let resolved = URL(fileURLWithPath: acpxPath).resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().appendingPathComponent("acpxd").path
    }
}
