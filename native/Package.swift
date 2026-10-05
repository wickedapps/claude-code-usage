// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ClaudeUsageNative", platforms: [.macOS(.v13)],
    products: [.executable(name: "ClaudeUsage", targets: ["ClaudeUsage"]), .library(name: "ClaudeUsageCore", targets: ["ClaudeUsageCore"])],
    targets: [.target(name: "ClaudeUsageCore"), .executableTarget(name: "ClaudeUsage", dependencies: ["ClaudeUsageCore"]), .testTarget(name: "ClaudeUsageCoreTests", dependencies: ["ClaudeUsageCore"]), .testTarget(name: "ClaudeUsageAppTests", dependencies: ["ClaudeUsage"])])
