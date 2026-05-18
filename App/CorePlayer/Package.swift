// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CorePlayer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CorePlayer", targets: ["CorePlayer"])
    ],
    dependencies: [],
    targets: [
        .target(name: "CorePlayer", dependencies: [])
    ],
    swiftLanguageModes: [.v6]
)
