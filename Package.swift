// swift-tools-version: 6.1
import PackageDescription

// The `SwiftACP` library is the cross-platform core — it depends only on the
// zero-dep JSONFoundation package, so it resolves and builds on macOS, Linux and
// Windows alike. The acpx CLI, the acpxd session daemon, their shared `ACPXCore`
// support library, and the protocol-validation tests are macOS-oriented (Bonjour
// service advertisement, POSIX signal handling, CryptoKit) and pull in SwiftMCP +
// swift-nio + service-lifecycle. They — and their heavier dependencies — are gated
// behind `#if os(macOS)` so the library stays dependency-light off-Apple platforms.

var products: [Product] = [
    // One module — `import SwiftACP` — covering both halves: the ACP protocol
    // + client (driving an agent) and the agent/server harness (exposing an
    // app/CLI as an ACP agent).
    .library(name: "SwiftACP", targets: ["SwiftACP"])
]

var dependencies: [Package.Dependency] = [
    // SwiftACP's only library dependency: the standalone, dependency-free
    // JSONFoundation package. As of 2.1.0 it carries not just the JSON value type,
    // JSON Schema and JSON-RPC 2.0 envelope, but the JSON-RPC *runtime* SwiftACP
    // used to hand-roll: a transport-agnostic peer (`JSONRPCPeer`), framing codecs
    // + the shared `ProcessLaunch` descriptor (`JSONRPCWire`), and a zero-dep
    // `Foundation.Process` stdio transport (`JSONRPCStdio`). We depend on those
    // three pure/zero-dep products only — not the `JSONRPC` umbrella, which would
    // pull in the SSE transport (and SwiftCross) we don't use.
    .package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "2.1.1")
]

var targets: [Target] = [
    .target(
        name: "SwiftACP",
        dependencies: [
            .product(name: "JSONFoundation", package: "JSONFoundation"),
            .product(name: "JSONRPCPeer", package: "JSONFoundation"),
            .product(name: "JSONRPCWire", package: "JSONFoundation"),
            .product(name: "JSONRPCStdio", package: "JSONFoundation")
        ]
    ),
    .testTarget(
        name: "SwiftACPTests",
        dependencies: ["SwiftACP"],
        exclude: ["Fixtures/mock-agent.py"]
    )
]

#if os(macOS)
products += [
    // The shared, iOS-capable client library: the daemon's MCP tool DTOs + the
    // `@MCPServer` shell whose generated `Client` an iOS app uses to drive a remote
    // `acpxd` over MCP. Host-gated to Apple platforms (it pulls SwiftMCP), but it
    // *builds for iOS*; off-Apple hosts keep just the light `SwiftACP` core.
    .library(name: "ACPXDaemonKit", targets: ["ACPXDaemonKit"]),
    // The headless CLI — a faithful clone of openclaw/acpx 0.11.0.
    .executable(name: "acpx", targets: ["acpx"]),
    // The session daemon: an MCP server (Bonjour + local TCP) holding live ACP sessions.
    .executable(name: "acpxd", targets: ["acpxd"]),
    // A tiny reference ACP agent built on the server half (for protocol validation).
    .executable(name: "acp-mock-agent", targets: ["acp-mock-agent"])
]

dependencies += [
    // SwiftMCP provides the MCP server/client + the TCP+Bonjour transport used
    // for the daemon IPC (à la Cocoanetics/Post). `Client` (the swift-nio-free
    // `MCPServerProxy` that `ACPXDaemonKit`'s generated `ACPXDaemon.Client` needs) is
    // always on; the swift-nio/crypto/certificates `Server` transports — used only by
    // acpxd — are gated behind this package's `Server` trait, so a client-only
    // consumer (e.g. an iOS app on just `ACPXDaemonKit`) drops the whole NIO stack.
    .package(url: "https://github.com/Cocoanetics/SwiftMCP.git", from: "1.7.0", traits: [
        "Client",
        .trait(name: "Server", condition: .when(traits: ["Server"])),
        .trait(name: "OpenAPI", condition: .when(traits: ["Server"]))
    ]),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    // ServiceGroup runs the daemon's transports (Bonjour + optional HTTP+SSE)
    // together with graceful SIGINT/SIGTERM shutdown.
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0")
]

targets += [
    // The shared, iOS-capable library: daemon MCP tool DTOs + the `@MCPServer`
    // `ACPXDaemon` shell (pure backend delegation) whose generated `Client` an iOS
    // app uses to talk to a remote `acpxd`. SwiftMCP + JSONFoundation only, so it
    // builds for iOS (with SwiftMCP's `Client` trait, no swift-nio).
    .target(
        name: "ACPXDaemonKit",
        dependencies: [
            .product(name: "SwiftMCP", package: "SwiftMCP"),
            .product(name: "JSONFoundation", package: "JSONFoundation")
        ]
    ),
    // Shared CLI/daemon core: config, session persistence, paths, records.
    .target(
        name: "ACPXCore",
        dependencies: [
            "ACPXDaemonKit",
            "SwiftACP",
            .product(name: "JSONFoundation", package: "JSONFoundation"),
            .product(name: "Logging", package: "swift-log")
        ]
    ),
    .executableTarget(
        name: "acp-mock-agent",
        dependencies: [
            "SwiftACP",
            .product(name: "JSONFoundation", package: "JSONFoundation")
        ]
    ),
    .executableTarget(
        name: "acpx",
        dependencies: [
            "SwiftACP",
            "ACPXCore",
            .product(name: "JSONFoundation", package: "JSONFoundation"),
            .product(name: "SwiftMCP", package: "SwiftMCP"),
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ]
    ),
    .executableTarget(
        name: "acpxd",
        dependencies: [
            "SwiftACP",
            "ACPXCore",
            .product(name: "JSONFoundation", package: "JSONFoundation"),
            .product(name: "SwiftMCP", package: "SwiftMCP"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ]
    ),
    .testTarget(
        name: "ACPTests",
        dependencies: [
            "SwiftACP",
            "ACPXCore", "acpx", "acpxd",
            .product(name: "SwiftMCP", package: "SwiftMCP")
        ],
        exclude: ["Fixtures/mock-agent.py"]
    )
]
#endif

let package = Package(
    name: "SwiftACP",
    platforms: [
        .macOS(.v14),
        // The SwiftACP *library* builds for iOS too: an iOS app can't spawn agents
        // (no `Foundation.Process`), but it can drive a remote `acpxd` over MCP and
        // render its ACP value types. The spawn-client (`ACPAgent`) and the
        // macOS-only CLI/daemon targets are gated out off-Apple-desktop.
        .iOS(.v15)
    ],
    products: products,
    traits: [
        // `Server` (default-on) enables SwiftMCP's swift-nio-backed `Server`
        // transports that acpxd serves over. A client-only consumer — e.g. an iOS app
        // that uses only `ACPXDaemonKit`'s generated `ACPXDaemon.Client` — disables it
        // (`.package(url: "…/SwiftACP…", traits: [])`) to resolve a swift-nio-free graph.
        .default(enabledTraits: ["Server"]),
        .trait(name: "Server")
    ],
    dependencies: dependencies,
    targets: targets
)
