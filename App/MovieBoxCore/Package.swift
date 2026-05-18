// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MovieBoxCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MovieBoxCore", targets: ["MovieBoxCore"]),
    ],
    dependencies: [
        .package(path: "../CoreMetadata"),
        .package(path: "../CoreTorrent"),
        .package(path: "../CorePlayer"),
        .package(path: "../CoreStorage"),
        .package(path: "../CoreStreaming"),
    ],
    targets: [
        .target(
            name: "MovieBoxCore",
            dependencies: [
                "CoreMetadata",
                "CoreTorrent",
                "CorePlayer",
                "CoreStorage",
                "CoreStreaming",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
