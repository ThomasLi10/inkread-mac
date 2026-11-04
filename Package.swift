// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InkRead",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "InkRead", targets: ["InkRead"]),
        .library(name: "InkReadCore", targets: ["InkReadCore"]),
        .library(name: "CodexBridge", targets: ["CodexBridge"])
    ],
    targets: [
        .target(name: "InkReadCore"),
        .target(name: "CodexBridge"),
        .executableTarget(name: "InkRead", dependencies: ["InkReadCore", "CodexBridge"]),
        .testTarget(name: "InkReadCoreTests", dependencies: ["InkReadCore"]),
        .testTarget(name: "CodexBridgeTests", dependencies: ["CodexBridge"])
    ],
    swiftLanguageVersions: [.v5]
)
