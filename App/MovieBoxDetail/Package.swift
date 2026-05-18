// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MovieBoxDetail",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MovieBoxDetail", targets: ["MovieBoxDetail"]),
    ],
    dependencies: [
        .package(path: "../MovieBoxCore"),
        .package(path: "../CoreMetadata"),
        .package(path: "../CoreTorrent"),
        .package(path: "../CorePlayer"),
        .package(path: "../CoreStorage"),
        .package(path: "../CoreStreaming"),
    ],
    targets: [
        .target(
            name: "MovieBoxDetail",
            dependencies: [
                "MovieBoxCore",
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
