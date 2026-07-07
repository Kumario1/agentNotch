// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agentNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "agentNotch"),
        .executableTarget(name: "agentnotch-hook"),
        .testTarget(name: "agentNotchTests", dependencies: ["agentNotch"]),
    ]
)
