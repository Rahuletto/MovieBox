// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CoreMetadata",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CoreMetadata", targets: ["CoreMetadata"])
    ],
    targets: [
        .target(name: "CoreMetadata")
    ],
    swiftLanguageModes: [.v6]
)
