// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SoundIsolation",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
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
