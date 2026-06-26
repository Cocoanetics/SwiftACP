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
    // JSONFoundation package (JSON value type + JSON Schema + JSON-RPC 2.0
    // types), split out of SwiftMCP.
    .package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "2.0.0")
]

var targets: [Target] = [
    .target(
        name: "SwiftACP",
        dependencies: [
            .product(name: "JSONFoundation", package: "JSONFoundation")
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
    // SwiftMCP provides the MCP server/client + the TCP+Bonjour transport used
    // for the daemon IPC (à la Cocoanetics/Post).
    .package(url: "https://github.com/Cocoanetics/SwiftMCP.git", from: "1.7.0"),
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
        .macOS(.v14)
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
