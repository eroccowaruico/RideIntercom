// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AudioCore",
    platforms: [
        .iOS("26.4"),
        .macOS("26.4"),
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
