// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agentNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "agentNotch", resources: [.process("Resources")]),
        .executableTarget(name: "agentnotch-hook"),
        .testTarget(name: "agentNotchTests", dependencies: ["agentNotch"]),
    ]
)
