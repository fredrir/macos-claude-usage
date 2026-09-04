# Development workflow

The Swift package is the fast command-line build and test surface. XcodeGen provides a reproducible macOS application
project without checking in Xcode's generated project or per-user state.

## Requirements

- macOS 14 or later;
- Xcode 16 or later with a Swift 6 toolchain;
- XcodeGen 2.45.4 or later when working in Xcode.

Install XcodeGen with Homebrew if needed, then generate the project from the checked-in specification:

```bash
brew install xcodegen
xcodegen generate
open ClaudeUsage.xcodeproj
```

`project.yml` is the source of truth. `ClaudeUsage.xcodeproj`, `xcuserdata`, Derived Data, build products, and release
artifacts are intentionally ignored.

## Local checks

Run the same checks as CI before opening a pull request:

```bash
swift build -Xswiftc -swift-version -Xswiftc 6
swift test -Xswiftc -swift-version -Xswiftc 6
xcodegen generate
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release CODE_SIGNING_ALLOWED=NO build
swift format lint --configuration .swift-format --recursive --parallel --strict Sources Tests Package.swift
plutil -lint Resources/Info.plist Configuration/ClaudeUsage.release.entitlements
bash -n build.sh screenshots.sh Scripts/release.sh
./screenshots.sh --check
```

The screenshot command renders pinned Claude and Codex fixtures with a pinned clock. It does not read credentials or
contact live usage services. Unit tests use injected clients and fixtures; live usage requests are not allowed in CI.

For signing and notarization, see [Security and distribution decisions](security-and-distribution.md).
