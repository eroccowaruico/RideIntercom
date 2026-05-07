// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SessionManager",
    platforms: [
        .iOS("26.4"),
        .macOS("26.4"),
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
