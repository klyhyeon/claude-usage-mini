// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageMini",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeUsageMini", path: "Sources")
    ]
)
