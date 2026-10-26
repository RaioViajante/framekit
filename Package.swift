// swift-tools-version: 6.0
import PackageDescription

// FrameKit's Swift package. Today it holds the caption configuration contract (presets and caption
// input, with their validation) and the rendering engine; the `framekit` CLI comes later.
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
