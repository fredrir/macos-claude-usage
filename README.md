# Claude Usage

A macOS menu bar app showing how much Claude Code and Codex quota you have left.

Requires macOS 26 or later.

## Screenshots

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dropdown-dark.png">
  <img src="docs/screenshots/dropdown-light.png" width="292" alt="Status menu listing Claude and Codex usage windows with usage bars and reset times">
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

## Developer tools

```sh
./Scripts/screenshots.sh        # rewrite docs/screenshots/ from the real menu
ClaudeUsage --dump              # print the resolved Claude windows
ClaudeUsage --dump-codex        # print the resolved Codex windows
ClaudeUsage --verify-refresh    # check the in-menu refresh control still receives clicks
```

The screenshots are captured from the status menu itself, so the committed images carry whatever
menu material the macOS build that produced them draws. Regenerate them on a matching OS.