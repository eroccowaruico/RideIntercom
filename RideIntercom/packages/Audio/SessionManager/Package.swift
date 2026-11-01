// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SessionManager",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
        .watchOS("27.0"),
    ],
    products: [
        .library(
            name: "SessionManager",
            targets: ["SessionManager"]
        ),
    ],
    dependencies: [
        .package(path: "../AudioCore"),
    ],
    targets: [
        .target(
            name: "SessionManager",
            dependencies: ["AudioCore"]
        ),
        .testTarget(
            name: "SessionManagerTests",
            dependencies: ["SessionManager", "AudioCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
