// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Codec",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
        .watchOS("27.0"),
    ],
    products: [
        .library(
            name: "Codec",
            targets: ["Codec"]
        ),
    ],
    dependencies: [
        .package(path: "../AudioCore"),
    ],
    targets: [
        .target(
            name: "Codec",
            dependencies: ["AudioCore"]
        ),
        .testTarget(
            name: "CodecTests",
            dependencies: [
                "Codec",
                "AudioCore",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
