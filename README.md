# Claude Usage

A macOS menu bar app showing how much Claude Code and Codex quota you have left.

## Screenshots

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dropdown-dark.png">
  <img src="docs/screenshots/dropdown-light.png" width="292" alt="Dropdown listing Claude and Codex usage windows with usage bars and reset times">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menubar-dark.png">
  <img src="docs/screenshots/menubar-light.png" width="51" alt="Menu bar: two vertical segmented gauges">
</picture>

## Install

```sh
./Scripts/build.sh
open ~/Applications/ClaudeUsage.app
./Scripts/build.sh --signing-identity "Developer ID Application: <YOUR-NAME> (<TEAM-ID>)"
```

> Pre-compiled binaries coming soon!