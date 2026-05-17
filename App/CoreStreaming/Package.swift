// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CoreStreaming",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CoreStreaming", targets: ["CoreStreaming"])
    ],
    dependencies: [
        .package(path: "../CoreTorrent"),
        .package(path: "../CoreStorage")
    ],
    targets: [
        .target(name: "CoreStreaming", dependencies: ["CoreTorrent", "CoreStorage"]),
        .testTarget(name: "CoreStreamingTests", dependencies: ["CoreStreaming"])
    ],
    swiftLanguageModes: [.v6]
)
