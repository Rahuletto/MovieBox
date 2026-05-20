// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"])
    ],
    dependencies: [
        .package(path: "../CoreMetadata")
    ],
    targets: [
        .target(
            name: "DesignSystem",
            dependencies: [
                "CoreMetadata"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
