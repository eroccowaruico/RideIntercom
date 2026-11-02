// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RTC",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
        .watchOS("27.0"),
    ],
    products: [
        .library(
            name: "RTC",
            targets: ["RTC"]
        ),
        .library(
            name: "RTCNativeWebRTC",
            targets: ["RTCNativeWebRTC"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "RTC"
        ),
        .target(
            name: "RTCNativeWebRTC",
            dependencies: [
                "RTC",
                "WebRTC",
            ]
        ),
        .binaryTarget(
            name: "WebRTC",
            path: "BinaryArtifacts/WebRTC/WebRTC.xcframework.zip"
        ),
        .testTarget(name: "RTCNativeWebRTCTests", dependencies: ["RTC", "RTCNativeWebRTC"]),
        .testTarget(
            name: "RTCTests",
            dependencies: ["RTC"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
