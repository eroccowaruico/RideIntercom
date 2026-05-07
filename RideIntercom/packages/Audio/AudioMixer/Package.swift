// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AudioMixer",
    platforms: [
        .iOS("26.4"),
        .macOS("26.4"),
    ],
    products: [
        .library(
            name: "AudioMixer",
            targets: ["AudioMixer"]
        ),
    ],
    dependencies: [
        .package(path: "../AudioCore"),
    ],
    targets: [
        .target(
            name: "AudioMixer",
            dependencies: ["AudioCore"]
        ),
        .testTarget(
            name: "AudioMixerTests",
            dependencies: [
                "AudioMixer",
                "AudioCore",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
