// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agentNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "agentNotch"),
        .testTarget(name: "agentNotchTests", dependencies: ["agentNotch"]),
    ]
)
