import ACPXCore
import Foundation
import SwiftACP
import SwiftMCP

// Reaching acpxd: by the `127.0.0.1` port its lock records, starting it when asked.
// Split from `DaemonClient.swift`.
extension DaemonClient {
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
        try await connectToDaemon(
            spawnIfNeeded: spawnIfNeeded, daemonExecutable: daemonExecutable, configure: configure
        ).proxy
    }

    /// A daemon connected to: its proxy, and the pid of the acpxd behind it — the lock's holder
    /// whose port the proxy reached, read with it, or this process for a stand-in (``standIn``),
    /// which runs here.
    struct ConnectedDaemon {
        let proxy: MCPServerProxy
        let pid: Int32
    }

    /// ``connect(spawnIfNeeded:daemonExecutable:configure:)``, saying which acpxd it reached.
    static func connectToDaemon(
        spawnIfNeeded: Bool, daemonExecutable: String? = nil,
        configure: @Sendable (MCPServerProxy) async -> Void = { _ in }
    ) async throws -> ConnectedDaemon {
        if let daemon = await tryConnectLive(configure: configure) {
            return daemon
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
        // start, and waiting on is pointless — its end cuts the wait under way short, so
        // the report need not wait for the poll to come round. One that lost the
        // singleton race exits cleanly, so we still resolve to the one running manager.
        // Called off, it stops waiting (a flow's stop, #219 review).
        for _ in 0 ..< 60 {
            try await startup.pause(for: .milliseconds(150))
            if let daemon = await tryConnect(holder: liveHolder(), configure: configure) {
                return daemon
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
    ) async -> ConnectedDaemon? {
        if let standIn {
            return await tryConnect(to: standIn, configure: configure)
                .map { ConnectedDaemon(proxy: $0, pid: ProcessInfo.processInfo.processIdentifier) }
        }
        return await tryConnect(holder: liveHolder(), configure: configure)
    }

    /// Try to connect to `holder` at the port it recorded, which names it as the daemon reached.
    static func tryConnect(
        holder: DaemonLock.Holder?, configure: @Sendable (MCPServerProxy) async -> Void
    ) async -> ConnectedDaemon? {
        guard let holder, let proxy = await tryConnect(endpoint(of: holder), configure: configure) else {
            return nil
        }
        return ConnectedDaemon(proxy: proxy, pid: holder.pid)
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
