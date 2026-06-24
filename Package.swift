// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SwiftACP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // One module — `import SwiftACP` — covering both halves: the ACP protocol
        // + client (driving an agent) and the agent/server harness (exposing an
        // app/CLI as an ACP agent).
        .library(name: "SwiftACP", targets: ["SwiftACP"])
    ],
    dependencies: [
        // Only JSONValue (zero-dep). Request SwiftMCP's `Client` trait so the
        // `Server` HTTP transport (swift-nio) stays out — nio-free consumers like
        // SwiftAgents can depend on SwiftACP and keep building on Windows.
        .package(path: "../SwiftMCP", traits: ["Client"])
    ],
    targets: [
        .target(
            name: "SwiftACP",
            dependencies: [
                .product(name: "JSONValue", package: "SwiftMCP")
            ]
        ),
        .testTarget(
            name: "SwiftACPTests",
            dependencies: ["SwiftACP"],
            exclude: ["Fixtures/mock-agent.py"]
        )
    ]
)
