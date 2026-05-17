// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CorePlayer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CorePlayer", targets: ["CorePlayer"])
    ],
    dependencies: [
        // Uncomment to use SwiftVLC for native MKV/DTS/AC3 playback
        // .package(url: "https://github.com/harflabs/SwiftVLC.git", from: "0.8.0")
    ],
    targets: [
        .target(
            name: "CorePlayer",
            dependencies: [
                // Uncomment to use SwiftVLC for native MKV/DTS/AC3 playback
                // .product(name: "SwiftVLC", package: "SwiftVLC")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
