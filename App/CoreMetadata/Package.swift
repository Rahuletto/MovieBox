// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CoreMetadata",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CoreMetadata", targets: ["CoreMetadata"])
    ],
    dependencies: [
        .package(url: "https://github.com/alexeichhorn/YouTubeKit", branch: "main")
    ],
    targets: [
        .target(
            name: "CoreMetadata",
            dependencies: [
                .product(name: "YouTubeKit", package: "YouTubeKit")
            ],
            linkerSettings: [
                .linkedFramework("Network")
            ]
        ),
        .testTarget(
            name: "CoreMetadataTests",
            dependencies: ["CoreMetadata"]
        )
    ],
    swiftLanguageModes: [.v6]
)
