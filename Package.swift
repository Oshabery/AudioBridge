// swift-tools-version: 6.0
//
// AudioBridge: Spike S2 (Mac receiver + test sender).
// The iOS Media Device Extension target is added later in an Xcode project,
// after the iOS 27 SDK and the managed entitlement have been confirmed (see docs/).

import PackageDescription

let package = Package(
    name: "AudioBridge",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "AudioBridgeCore", targets: ["AudioBridgeCore"]),
        .library(name: "AudioBridgeApple", targets: ["AudioBridgeApple"]),
        .executable(name: "abrecv", targets: ["abrecv"]),
        .executable(name: "abtone", targets: ["abtone"]),
    ],
    targets: [
        // Platform-neutral, realtime-safe building blocks (no Foundation dependency).
        .target(name: "AudioBridgeCore"),
        // Network.framework transport + AVAudioEngine playout (Apple platforms only).
        .target(name: "AudioBridgeApple", dependencies: ["AudioBridgeCore"]),
        .executableTarget(name: "abrecv", dependencies: ["AudioBridgeCore", "AudioBridgeApple"]),
        .executableTarget(name: "abtone", dependencies: ["AudioBridgeCore", "AudioBridgeApple"]),
        .testTarget(name: "AudioBridgeCoreTests", dependencies: ["AudioBridgeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
