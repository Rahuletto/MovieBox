// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MoviePlayer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MoviePlayerUI", targets: ["MoviePlayerUI"]),
        .library(name: "MoviePlayerEngine", targets: ["MoviePlayerEngine"]),
        .library(name: "MoviePlayerKit", targets: ["MoviePlayerKit"]),
        .library(name: "MoviePlayer", targets: ["MoviePlayerKit"]),
    ],
    dependencies: [
        .package(path: "../CoreStorage"),
    ],
    targets: [
        .target(
            name: "MoviePlayerUI",
            dependencies: ["MoviePlayerEngine"],
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "MoviePlayerEngine",
            dependencies: ["CoreStorage"]
        ),
        .target(
            name: "MoviePlayerKit",
            dependencies: ["MoviePlayerUI", "MoviePlayerEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
