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
        .package(path: "../CoreStorage"),
        .package(path: "../MoviePlayer"),
    ],
    targets: [
        .target(
            name: "CoreStreaming",
            dependencies: [
                "CoreTorrent",
                "CoreStorage",
                .product(name: "MoviePlayerEngine", package: "MoviePlayer"),
            ]
        ),
        .testTarget(
            name: "CoreStreamingTests",
            dependencies: [
                "CoreStreaming",
                "CoreStorage",
                "CoreTorrent",
                .product(name: "MoviePlayerEngine", package: "MoviePlayer"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
