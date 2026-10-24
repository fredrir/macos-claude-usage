// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"]),
        .library(name: "UsageCore", targets: ["UsageCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0")
    ],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: ["UsageCore", "KeyboardShortcuts"],
            path: "Sources/ClaudeUsage",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
