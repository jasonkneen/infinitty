// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "infinitty",
    platforms: [.macOS(.v14)],
    dependencies: [
        // ShadKit — SwiftUI port of shadcn/ui + Vercel AI Elements.
        // https://github.com/jasonkneen/ShadKit
        //
        // A sibling checkout rather than a version pin, so edits over there are
        // picked up here without a tag and push each time. Swap to
        // `.package(url: …, from: "0.1.0")` once it settles.
        .package(path: "../ShadKit"),
    ],
    targets: [
        .target(name: "CPty"),
        .target(
            name: "InfinittyKit",
            dependencies: [
                "CPty",
                .product(name: "ShadcnUI", package: "ShadKit"),
                .product(name: "AIElementsUI", package: "ShadKit"),
                .product(name: "AIElementsGallery", package: "ShadKit"),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "infinitty",
            dependencies: ["InfinittyKit"]
        ),
        .executableTarget(
            name: "infinitty-mcp"
        ),
        .executableTarget(
            name: "infinitty-agent"
        ),
        .testTarget(
            name: "InfinittyKitTests",
            dependencies: ["InfinittyKit"]
        ),
    ]
)
