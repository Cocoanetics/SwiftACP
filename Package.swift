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
        // SwiftACP's only dependency: the standalone, dependency-free JSONValue
        // package (split out of SwiftMCP). Consumers developing against a local
        // JSONValue checkout can override with a sibling path dependency.
        .package(url: "https://github.com/Cocoanetics/JSONValue.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "SwiftACP",
            dependencies: [
                .product(name: "JSONValue", package: "JSONValue")
            ]
        ),
        .testTarget(
            name: "SwiftACPTests",
            dependencies: ["SwiftACP"],
            exclude: ["Fixtures/mock-agent.py"]
        )
    ]
)
