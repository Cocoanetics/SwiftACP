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
        defer { lock.release() }

        let daemon = ACPXDaemon(inheritAgentStderr: verbose)

        // The Bonjour + local TCP transport is always on — the CLI finds the daemon this way.
        let bonjour = TCPBonjourTransport(server: daemon, serviceName: "acpx")
        var services: [ServiceGroupConfiguration.ServiceConfiguration] = [
            .init(service: bonjour, successTerminationBehavior: .gracefullyShutdownGroup)
        ]
        var summary = "Bonjour + local TCP"

        // Optional outward MCP over HTTP+SSE. No auth yet — every request is authorized.
        if let httpPort {
            let http = HTTPSSETransport(server: daemon, host: httpHost, port: httpPort)
            http.authorizationHandler = { _ in .authorized }
            services.append(
                .init(service: http, successTerminationBehavior: .gracefullyShutdownGroup))
            summary += " + HTTP+SSE http://\(httpHost):\(httpPort)/sse (UNAUTHENTICATED)"
        }

        log.info("acpxd: MCP server 'acpx' listening (\(summary))")

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
