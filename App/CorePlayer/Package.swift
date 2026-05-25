// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CorePlayer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CorePlayer", targets: ["CorePlayer"])
    ],
    dependencies: [
        .package(path: "../MoviePlayer"),
    ],
    targets: [
        .target(
            name: "CorePlayer",
            dependencies: [
                .product(name: "MoviePlayerUI", package: "MoviePlayer"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
