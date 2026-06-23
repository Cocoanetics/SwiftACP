// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SwiftACP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // The ACP protocol + client (nio-free; only JSONValue).
        .library(name: "ACP", targets: ["ACP"]),
        // The agent/server half: expose an app/CLI as an ACP agent (nio-free).
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
        .testTarget(
            name: "SwiftACPTests",
            dependencies: ["ACP", "ACPServer"],
            exclude: ["Fixtures/mock-agent.py"]
        )
    ]
)
