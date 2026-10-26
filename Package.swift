// swift-tools-version: 6.0
import PackageDescription

// FrameKit's Swift package. Today it holds only the caption configuration contract (presets and
// caption input, with their validation); the rendering engine and the `framekit` CLI come later.
// No external dependencies. Decisions: docs/decisions/0001-caption-configuration.md
let package = Package(
    name: "FrameKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrameKitCaptions", targets: ["FrameKitCaptions"]),
    ],
    targets: [
        .target(name: "FrameKitCaptions"),
        .testTarget(name: "FrameKitCaptionsTests", dependencies: ["FrameKitCaptions"]),
    ]
)
