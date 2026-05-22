// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CoreTorrent",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CoreTorrent", targets: ["CoreTorrent"])
    ],
    targets: [
        .target(name: "CoreTorrent"),
    ],
    swiftLanguageModes: [.v6]
)
