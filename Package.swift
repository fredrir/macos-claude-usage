// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"]),
        .library(name: "UsageCore", targets: ["UsageCore"]),
    ],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: ["UsageCore"],
            path: "Sources/ClaudeUsage",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: ["ClaudeUsage", "UsageCore"],
            path: "Tests/ClaudeUsageTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
