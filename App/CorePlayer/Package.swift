// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CorePlayer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CorePlayer", targets: ["CorePlayer"])
    ],
    targets: [
        .target(name: "CorePlayer")
    ],
    swiftLanguageModes: [.v6]
)
