// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SoundIsolation",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: [
        .library(
            name: "SoundIsolation",
            targets: ["SoundIsolation"]
        ),
    ],
    targets: [
        .target(
            name: "SoundIsolation"
        ),
        .testTarget(
            name: "SoundIsolationTests",
            dependencies: ["SoundIsolation"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
