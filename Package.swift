// swift-tools-version: 6.1
import PackageDescription

// `SwiftACP` is the single library you import — the ACP protocol + value types, the
// agent/server harness, AND the generated `ACPXDaemon.Client` for driving a remote
// `acpxd` over MCP. It depends on JSONFoundation (zero-dep) and SwiftMCP's swift-nio-
// free `Client` trait. The swift-nio `Server` transports (used only by the acpxd
// daemon) sit behind this package's default-on `Server` trait, so a client-only
// consumer — an iOS or Android app — disables `Server` for a swift-nio-free graph.
//
// The acpx CLI, the acpxd session daemon, their shared `ACPXCore` support library,
// and the protocol-validation tests are macOS-oriented (Bonjour, POSIX signals,
// CryptoKit) and are gated behind `#if os(macOS)`. The spawn-client (`ACPAgent`) is
// gated to desktop platforms — there is no `Foundation.Process` on iOS/Android.

var products: [Product] = [
    // One module — `import SwiftACP`: the ACP protocol + the desktop spawn-client
    // (driving a local agent), the agent/server harness, and the MCP `ACPXDaemon.Client`
    // for driving a remote `acpxd` (every platform, including iOS and Android).
    .library(name: "SwiftACP", targets: ["SwiftACP"])
]

var dependencies: [Package.Dependency] = [
    // JSONFoundation: JSON value type, JSON Schema, JSON-RPC 2.0 envelope, and the
    // JSON-RPC runtime (peer, framing, stdio transport) the ACP transports build on.
    .package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "2.1.2",
             traits: ["Subprocess"]),
    // SwiftMCP: the MCP client (`MCPServerProxy`, swift-nio-free `Client` trait) that
    // SwiftACP's generated `ACPXDaemon.Client` uses, and — behind this package's
    // default-on `Server` trait — the swift-nio TCP/Bonjour/HTTP-SSE server transports
    // acpxd serves over. A client-only consumer (an iOS/Android app) disables `Server`.
    .package(url: "https://github.com/Cocoanetics/SwiftMCP.git", from: "1.7.0", traits: [
        "Client",
        .trait(name: "Server", condition: .when(traits: ["Server"])),
        .trait(name: "OpenAPI", condition: .when(traits: ["Server"]))
    ])
]

var targets: [Target] = [
    .target(
        name: "SwiftACP",
        dependencies: [
            .product(name: "JSONFoundation", package: "JSONFoundation"),
            .product(name: "JSONRPCPeer", package: "JSONFoundation"),
            .product(name: "JSONRPCWire", package: "JSONFoundation"),
            // The swift-subprocess child stdio transport for the desktop spawn-client.
            // swift-subprocess sets an iOS "99.0" floor, so it's pulled in only where
            // agents actually spawn — iOS/Android get the client-only graph without it.
            .product(name: "JSONRPCSubprocess", package: "JSONFoundation",
                     condition: .when(platforms: [.macOS, .linux, .windows])),
            .product(name: "SwiftMCP", package: "SwiftMCP")
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
    // The headless CLI — a faithful clone of openclaw/acpx 0.11.0.
    .executable(name: "acpx", targets: ["acpx"]),
    // The session daemon: an MCP server (Bonjour + local TCP) holding live ACP sessions.
    .executable(name: "acpxd", targets: ["acpxd"]),
    // A tiny reference ACP agent built on the server half (for protocol validation).
    .executable(name: "acp-mock-agent", targets: ["acp-mock-agent"])
]

dependencies += [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    // ServiceGroup runs the daemon's transports (Bonjour + optional HTTP+SSE)
    // together with graceful SIGINT/SIGTERM shutdown.
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0")
]

targets += [
    // Shared CLI/daemon core: config, session persistence, paths, records.
    .target(
        name: "ACPXCore",
        dependencies: [
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
        // The library builds for iOS (and cross-compiles for Android): no agent
        // spawning there, but it drives a remote `acpxd` over MCP via the generated
        // `ACPXDaemon.Client` and renders ACP value types. The spawn-client and the
        // macOS-only CLI/daemon targets are gated out.
        .iOS(.v15)
    ],
    products: products,
    traits: [
        // `Server` (default-on) pulls SwiftMCP's swift-nio TCP/Bonjour/HTTP-SSE server
        // transports that acpxd serves over. A client-only consumer — an iOS or Android
        // app on `SwiftACP` — disables it (`.package(url: "…/SwiftACP…", traits: [])`)
        // to resolve a swift-nio-free graph.
        .default(enabledTraits: ["Server"]),
        .trait(name: "Server")
    ],
    dependencies: dependencies,
    targets: targets
)
