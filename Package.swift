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
        // SwiftACP's only dependency: the standalone, dependency-free
        // JSONFoundation package (JSON value type + JSON Schema + JSON-RPC 2.0
        // types), split out of SwiftMCP.
        .package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "1.1.0")
    ],
    targets: [
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
)
