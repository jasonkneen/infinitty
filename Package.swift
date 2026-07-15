// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "infinitty",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CPty"),
        .target(
            name: "InfinittyKit",
            dependencies: ["CPty"],
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        ),
        .executableTarget(
            name: "infinitty",
            dependencies: ["InfinittyKit"]
        ),
        .executableTarget(
            name: "infinitty-mcp"
        ),
        .testTarget(
            name: "InfinittyKitTests",
            dependencies: ["InfinittyKit"]
        ),
    ]
)
