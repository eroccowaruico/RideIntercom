// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "EffectSoundIsolation",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "EffectSoundIsolation",
            targets: ["EffectSoundIsolation"]
        ),
    ],
    targets: [
        .target(
            name: "EffectSoundIsolation"
        ),
        .testTarget(
            name: "EffectSoundIsolationTests",
            dependencies: ["EffectSoundIsolation"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
