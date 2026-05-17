// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CoreStorage",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CoreStorage", targets: ["CoreStorage"])
    ],
    targets: [
        .target(name: "CoreStorage")
    ],
    swiftLanguageModes: [.v6]
)
