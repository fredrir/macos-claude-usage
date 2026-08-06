# Claude Usage

A macOS menu bar app showing how much Claude Code quota you have left.

Collapsed, it shows two segmented gauges — **current session** and **weekly Fable** —
each with the percentage still available:

```
▰▰▰▰▱▱▱ 58%  ▰▰▰▰▰▱▱ 82%
```

Click it for every limit window the account reports: current session, current week across
all models, current week for Fable, and whichever extra windows exist (Opus, Sonnet, …).

## Install

```sh
./build.sh                # builds, signs, installs to ~/Applications
open ~/Applications/ClaudeUsage.app
```

`./build.sh --no-install` leaves `ClaudeUsage.app` in the repo instead.

Requires the Swift toolchain from Xcode **or** the Command Line Tools — full Xcode is not
needed, the bundle is assembled by hand from a SwiftPM build.

On first launch macOS asks for permission to read the Claude Code credentials from your
Keychain. Choose **Always Allow**. Because the bundle is ad-hoc signed, its signature changes
on every rebuild, so the prompt reappears after a `./build.sh`.

## Where the numbers come from

`GET https://api.anthropic.com/api/oauth/usage` — the same endpoint behind Claude Code's own
`/usage` command. The OAuth token is read from the Keychain item Claude Code stores under the
service `Claude Code-credentials`.

Response fields, all confirmed against the Claude Code binary:

| Field | Meaning |
| --- | --- |
| `five_hour` | current session window |
| `seven_day` | current week, all models |
| `limits[]` | per-model weekly windows — `kind: "weekly_scoped"`, `scope.model.display_name` |
| `seven_day_opus`, `seven_day_sonnet`, … | additional weekly windows when the plan has them |

`utilization` (and `limits[].percent`) is a percentage **0–100**; `resets_at` is **unix
seconds**; a window whose `utilization` is `null` is hidden rather than drawn as 0%.

## Rate limiting

The endpoint is strict — it answers `429` with a `retry-after` measured in minutes, and
retrying *during* the penalty appears to extend it. Claude Code caches a successful response
for a full hour.

So the app is deliberately conservative:

- polls on a fixed interval (default 15 min, selectable 10/15/30/60 in the dropdown)
- never sends a request before a recorded `retry-after` has elapsed
- refreshes on menu-open only if the data has aged past half the poll interval
- exponential backoff, capped at an hour, for network and 5xx errors
- keeps the last good payload in `~/Library/Application Support/ClaudeUsage/usage.json`
  so a restart paints immediately; anything older than an hour renders dimmed

## Token refresh

The access token expires roughly every 8 hours. The app refreshes it itself against
`https://platform.claude.com/v1/oauth/token` and writes the result back to the same Keychain
item, so the menu bar keeps working even if you have not opened Claude Code.

Refresh tokens rotate, and rotating one out from under a running Claude Code session would
break that session's next refresh. The app therefore does the least it can get away with:

1. refreshes only once the token is expired or within 2 minutes of it, never proactively
2. re-reads the Keychain under a lock first — if Claude Code already refreshed, that token is
   used and no rotation happens
3. merges into the existing JSON so `scopes` / `subscriptionType` / `rateLimitTier` survive
4. serialises with a cross-process `flock` so two copies cannot refresh at once

If refresh fails the last good numbers stay on screen, dimmed, with a note to run `claude`
once.

## Development

```sh
swift build -c release --product ClaudeUsage

# print resolved windows and exit — handy for checking against /usage
./.build/release/ClaudeUsage --dump

# drive the UI from a JSON file instead of the live endpoint
CLAUDE_USAGE_FIXTURE=/path/to/fixture.json ./.build/release/ClaudeUsage
```

| File | Role |
| --- | --- |
| `Keychain.swift` | reads/writes the `Claude Code-credentials` item |
| `OAuth.swift` | credential model, refresh flow, cross-process lock |
| `UsageAPI.swift` | endpoint call, decoding, 429/401 handling |
| `UsageModel.swift` | normalises the response into an ordered `[Bucket]` |
| `UsageStore.swift` | polling, backoff, disk cache, status |
| `GaugeRenderer.swift` | draws the menu bar image |
| `StatusItemController.swift` | `NSStatusItem` + popover wiring |
| `DropdownView.swift` | SwiftUI dropdown |
