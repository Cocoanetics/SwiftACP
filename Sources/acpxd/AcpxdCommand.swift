import ACPXCore
import ArgumentParser
import Foundation
import Logging
import ServiceLifecycle
import SwiftMCP

/// `acpxd` — runs the ``ACPXDaemon`` MCP server over one or more transports.
@main
struct AcpxdCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acpxd",
        abstract:
            "The acpx session daemon: an MCP server (Bonjour + local TCP) holding live ACP sessions.",
        discussion: """
            Always serves a Bonjour + local TCP transport (how the `acpx` CLI discovers it).
            Pass --http-port to additionally expose the MCP server over HTTP+SSE for outward
            clients. Authentication is not implemented yet, so an HTTP port is unauthenticated;
            it binds to loopback (127.0.0.1) by default — pass --http-host 0.0.0.0 only if you
            intend it to be reachable from other machines.
            """)

    @Option(
        name: .customLong("http-port"),
        help: "Also serve MCP over HTTP+SSE on this port (outward, unauthenticated).")
    var httpPort: Int?

    @Option(
        name: .customLong("http-host"),
        help: "Bind address for the HTTP+SSE transport (loopback by default; pass 0.0.0.0 to expose).")
    var httpHost: String = "127.0.0.1"

    @Flag(
        name: .shortAndLong,
        help: "Inherit spawned agents' stderr (surfaces agent diagnostics like rate-limit messages).")
    var verbose = false

    func run() async throws {
        bootstrapACPXLogging()
        let log = Logger(label: "com.cocoanetics.acpx.acpxd")

        // Singleton guard: only one acpxd may own the live sessions + records at a
        // time. If another live daemon already holds the lock, exit cleanly — the
        // CLI will connect to that one. A stale lock (crashed daemon) is reclaimed.
        let lock = DaemonLock()
        guard try lock.acquire() else {
            log.notice("acpxd: another daemon is already running; exiting.")
            return
        }

        // The backend owns the live agent sessions and the singleton lock; it's run as
        // a service below so it closes those agents and releases the lock on shutdown.
        // The `@MCPServer` shell — served over the transports — delegates every tool to it.
        let backend = ACPXDaemonBackend(inheritAgentStderr: verbose, lock: lock)
        let daemon = ACPXDaemon(backend: backend)

        // The local TCP transport (also advertised via Bonjour) is always on. The CLI
        // connects to it directly by the port recorded in the lock file below.
        //
        // The daemon is registered first so — because ServiceGroup tears services down
        // in reverse — it shuts down LAST, after the transports stop serving. Both
        // termination behaviors are graceful so even a transport *failure* unwinds in
        // that order, rather than cancelling every task concurrently (which could drop
        // the lock while a transport is still draining).
        let bonjour = TCPBonjourTransport(server: daemon, serviceName: "acpx")
        var services: [ServiceGroupConfiguration.ServiceConfiguration] = [
            .init(
                service: backend, successTerminationBehavior: .gracefullyShutdownGroup,
                failureTerminationBehavior: .gracefullyShutdownGroup),
            .init(
                service: bonjour, successTerminationBehavior: .gracefullyShutdownGroup,
                failureTerminationBehavior: .gracefullyShutdownGroup)
        ]
        var summary = "Bonjour + local TCP"

        // Optional outward MCP over HTTP+SSE. No auth yet — every request is authorized.
        if let httpPort {
            let http = HTTPSSETransport(server: daemon, host: httpHost, port: httpPort)
            http.authorizationHandler = { _ in .authorized }
            services.append(.init(
                service: http, successTerminationBehavior: .gracefullyShutdownGroup,
                failureTerminationBehavior: .gracefullyShutdownGroup))
            summary += " + HTTP+SSE http://\(httpHost):\(httpPort)/sse (UNAUTHENTICATED)"
        }

        log.info("acpxd: MCP server 'acpx' listening (\(summary))")

        // Once the listener has a bound port, record it in the lock so the CLI can
        // connect directly (127.0.0.1:port) instead of via Bonjour discovery.
        let portRecorder = Task { [bonjour, lock, log] in
            for _ in 0 ..< 200 {
                if Task.isCancelled { return }
                if let port = bonjour.port {
                    lock.update(port: Int(port))
                    log.info("acpxd: listening on 127.0.0.1:\(port)")
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { portRecorder.cancel() }

        // A ServiceGroup owns the run loop for all transports and traps SIGINT/SIGTERM
        // for an ordered graceful shutdown.
        let group = ServiceGroup(
            configuration: .init(
                services: services,
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: log))
        try await group.run()
    }
}

extension ACPXDaemonBackend: Service {
    /// The daemon's lifecycle in the ``ServiceGroup``. Registered first, it's torn
    /// down LAST — after the transports stop accepting requests — so on graceful
    /// shutdown it closes every live agent (no orphaned subprocesses) and then
    /// releases the singleton lock. A forced cancellation isn't ordered, so we skip
    /// the lock release and let the next daemon reclaim the stale lock.
    func run() async throws {
        let graceful = await (try? gracefulShutdown()) != nil
        for sessionId in Array(live.keys) {
            await evict(sessionId)
        }
        if graceful { lock?.release() }
    }
}
