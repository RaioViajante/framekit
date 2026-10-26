// swift-tools-version: 6.0
import PackageDescription

// FrameKit's Swift package: the caption configuration contract (presets and caption input, with their
// validation), the rendering engine, and the `framekit` command line (docs/cli.md).
// No external dependencies. Decisions: docs/decisions/0001-caption-configuration.md
let package = Package(
    name: "FrameKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrameKitCaptions", targets: ["FrameKitCaptions"]),
        .executable(name: "framekit", targets: ["framekit"]),
    ],
    targets: [
        .target(name: "FrameKitCaptions"),
        .target(name: "FrameKitCLI", dependencies: ["FrameKitCaptions"]),
        .executableTarget(name: "framekit", dependencies: ["FrameKitCLI"]),
        .testTarget(name: "FrameKitCaptionsTests", dependencies: ["FrameKitCaptions"]),
        .testTarget(name: "FrameKitCLITests", dependencies: ["FrameKitCLI", "framekit"]),
    ]
)
