// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SwiftACP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Umbrella: `import SwiftACP` re-exports both halves below.
        .library(name: "SwiftACP", targets: ["SwiftACP"]),
        // The ACP protocol + client (only JSONValue).
        .library(name: "ACP", targets: ["ACP"]),
        // The agent/server half: expose an app/CLI as an ACP agent.
        .library(name: "ACPServer", targets: ["ACPServer"])
    ],
    dependencies: [
        // Only JSONValue (zero-dep). Request SwiftMCP's `Client` trait so the
        // `Server` HTTP transport (swift-nio) stays out — nio-free consumers like
        // SwiftAgents can depend on SwiftACP and keep building on Windows.
        .package(path: "../SwiftMCP", traits: ["Client"])
    ],
    targets: [
        .target(
            name: "ACP",
            dependencies: [
                .product(name: "JSONValue", package: "SwiftMCP")
            ]
        ),
        .target(
            name: "ACPServer",
            dependencies: [
                "ACP",
                .product(name: "JSONValue", package: "SwiftMCP")
            ]
        ),
        .target(
            name: "SwiftACP",
            dependencies: ["ACP", "ACPServer"]
        ),
        .testTarget(
            name: "SwiftACPTests",
            dependencies: ["SwiftACP", "ACP", "ACPServer"],
            exclude: ["Fixtures/mock-agent.py"]
        )
    ]
)
