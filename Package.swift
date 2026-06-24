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
        // SwiftACP uses only SwiftMCP's standalone, zero-dependency `JSONValue`
        // product — none of the MCP client/server. Enable no traits so the
        // `Server` trait's swift-nio/crypto/certs never enter resolution; SwiftACP
        // stays dependency-light and builds on Windows. Consumers developing
        // against a local SwiftMCP checkout can override with a sibling path dep.
        .package(url: "https://github.com/Cocoanetics/SwiftMCP.git", from: "1.5.1", traits: [])
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
