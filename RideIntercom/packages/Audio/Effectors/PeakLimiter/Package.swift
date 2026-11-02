// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "PeakLimiter",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: [
        .library(
            name: "PeakLimiter",
            targets: ["PeakLimiter"]
        ),
    ],
    targets: [
        .target(
            name: "PeakLimiter"
        ),
        .testTarget(
            name: "PeakLimiterTests",
            dependencies: ["PeakLimiter"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
