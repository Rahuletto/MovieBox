// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CoreMLEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CoreMLEngine", targets: ["CoreMLEngine"])
    ],
    targets: [
        .target(name: "CoreMLEngine")
    ],
    swiftLanguageModes: [.v6]
)
