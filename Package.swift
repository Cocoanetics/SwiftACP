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
        // `Server` HTTP transport (swift-nio) stays out — SwiftACP stays nio-free
        // (and keeps building on Windows). Consumers developing against a local
        // SwiftMCP checkout can override this with a sibling path dependency.
        .package(url: "https://github.com/Cocoanetics/SwiftMCP.git", from: "1.5.1", traits: ["Client"])
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
