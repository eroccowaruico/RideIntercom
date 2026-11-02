// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AudioCore",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
        .watchOS("27.0"),
    ],
    products: [
        .library(
            name: "AudioCore",
            targets: ["AudioCore"]
        ),
    ],
    targets: [
        .target(
            name: "AudioCore"
        ),
        .testTarget(
            name: "AudioCoreTests",
            dependencies: ["AudioCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
