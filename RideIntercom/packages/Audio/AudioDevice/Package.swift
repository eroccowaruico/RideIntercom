// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AudioDevice",
    platforms: [.iOS("27.0"), .macOS("27.0"), .watchOS("27.0")],
    products: [.library(name: "AudioDevice", targets: ["AudioDevice"])],
    dependencies: [.package(path: "../AudioCore"), .package(path: "../Codec"),
                   .package(path: "../SessionManager"), .package(path: "../../RTC")],
    targets: [
        .target(name: "AudioDevice", dependencies: ["AudioCore", "Codec", "SessionManager", "RTC"]),
        .testTarget(name: "AudioDeviceTests", dependencies: ["AudioDevice", "AudioCore", "Codec", "SessionManager", "RTC"])
    ],
    swiftLanguageModes: [.v6]
)
