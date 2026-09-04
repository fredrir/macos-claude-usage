# Claude Usage

A macOS menu bar app showing how much Claude Code and Codex quota you have left.

## Collapsed

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menubar-dark.png">
  <img src="docs/screenshots/menubar-light.png" width="51" alt="Menu bar: two vertical segmented gauges">
</picture>

## Dropdown

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dropdown-dark.png">
  <img src="docs/screenshots/dropdown-light.png" width="292" alt="Dropdown listing Claude and Codex usage windows with usage bars and reset times">
</picture>

## Install

```sh
./build.sh
open ~/Applications/ClaudeUsage.app
./build.sh --no-install # Leaves ClaudeUsage.app in the repo instead
```

> On first launch macOS asks for permission to read the Claude Code credentials from your
Keychain. Choose **Always Allow**.

Codex rows reuse the existing ChatGPT app or Codex CLI sign-in. Install and sign in to either
before launching Claude Usage.

```sh
./build.sh --signing-identity "Apple Development: Your Name (TEAMID)"
```

## Where the numbers come from

| Provider | Source | Authentication |
| --- | --- | --- |
| Claude | `GET https://api.anthropic.com/api/oauth/usage` | Claude Code Keychain item |
| Codex | `codex app-server` → `account/rateLimits/read` | Existing Codex/ChatGPT session |

The Codex app-server returns the main quota plus `rateLimitsByLimitId` model-specific quotas.
Each `primary` and `secondary` row uses the server's `windowDurationMins`, `usedPercent`, and
`resetsAt`; labels such as **5-hour limit** and **Weekly limit** are derived from that duration.
The dropdown includes populated model-specific windows except Codex Spark. The collapsed menu-bar gauges remain
Claude-only.

See the official [Codex app-server documentation](https://developers.openai.com/codex/app-server)
for the account protocol.

### Claude

`GET https://api.anthropic.com/api/oauth/usage` — the same endpoint behind Claude Code's own
`/usage` command. The OAuth token is read from the Keychain item Claude Code stores under the
service `Claude Code-credentials`.

`limits[]` is the authoritative view — every window in one array, each with a `severity` the
server has already worked out. The top-level keys duplicate the first two and are read only as
a fallback.

| Field | Meaning |
| --- | --- |
| `limits[]` `kind: "session"` | current session window |
| `limits[]` `kind: "weekly_all"` | current week, all models |
| `limits[]` `kind: "weekly_scoped"` | per-model weekly window — model in `scope.model.display_name` |
| `percent` | 0–100 consumed |
| `severity` | `normal` / `warning` / `critical` — drives the green/orange/red tint |
| `resets_at` | **ISO 8601 string**, e.g. `2026-08-06T21:00:00.290962+00:00` |
| `five_hour`, `seven_day`, `seven_day_opus`, … | fallback windows; most are `null` |

Two traps, both found the hard way against the live endpoint:

- `resets_at` is an **ISO 8601 string here**, even though the `anthropic-ratelimit-unified-*`
  response headers express the same concept as epoch seconds. Decoding it as a number fails
  the whole payload.
- It can carry microsecond precision. The app uses Swift's value-typed ISO 8601 parse strategy,
  which accepts whole-second, millisecond, and microsecond timestamps without shared mutable
  formatters.

A window whose percentage is `null` is hidden rather than drawn as 0%, which is why a plan
with no separate Opus window shows three rows rather than five.

## Rate limiting

This endpoint punishes eagerness, and the penalty **escalates**. Measured against the live
API: a first request answered `429` with `retry-after: 654`; after a burst of polling every
two minutes, a single request made following 15 minutes of complete silence still answered
`429`, now with `retry-after: 2023`. Requests made *during* a penalty extend it rather than
simply being refused. Claude Code itself caches a successful response for a full hour.

So the app is deliberately conservative:

- polls on a fixed interval (default 30 min, selectable 15/30/60 in the dropdown)
- never sends a request before a recorded `retry-after` has elapsed, plus a 60s margin so it
  cannot land on the boundary and re-trigger the penalty
- enforces a 15 minute floor between calls, so mashing Refresh cannot burn the budget
- refreshes on menu-open only if the data has aged past half the poll interval
- exponential backoff, capped at an hour, for network and 5xx errors
- keeps the last good payload in `~/Library/Application Support/ClaudeUsage/usage.json`
  and Codex payload in `codex-usage.json`, so a restart paints immediately; anything older than
  an hour renders dimmed
- persists provider schedules separately in `polling-state.json` and
  `codex-polling-state.json` *before* starting network
  work, so quitting or relaunching cannot bypass the 15-minute floor or a server penalty
- fetches Claude and Codex concurrently, so one provider cannot add latency to the other

If you ever see it stuck on "Rate limited", leave it alone — it is already waiting exactly as
long as the server asked, and poking it makes the wait longer.

## Authentication

| Provider | Behavior |
| --- | --- |
| Claude | Reads and refreshes the existing Claude Code Keychain credential |
| Codex | Delegates cached credentials and automatic refresh to `codex app-server` |

Claude Usage never reads, copies, or logs `~/.codex/auth.json`, and never starts a separate Codex
login flow. Codex automatically refreshes active ChatGPT sessions. If the session can no longer
refresh, the dropdown asks for one `codex login`; authentication failures back off for 15 minutes
instead of repeatedly invoking Codex. See the official
[Codex authentication documentation](https://developers.openai.com/codex/auth).

### Claude token refresh

Access token expires roughly every 8 hours. The app refreshes it itself against
`https://platform.claude.com/v1/oauth/token` and writes the result back to the same Keychain
item, so the menu bar keeps working even if you have not opened Claude Code.

Refresh tokens rotate, and rotating one out from under a running Claude Code session would
break that session's next refresh. The app therefore does the least it can get away with:

1. refreshes only once the token is expired or within 2 minutes of it, never proactively
2. re-reads the Keychain under a lock first — if Claude Code already refreshed, that token is
   used and no rotation happens
3. merges into the existing JSON so `scopes` / `subscriptionType` / `rateLimitTier` survive
4. updates the exact Keychain item by persistent reference rather than every item with the same
   service name
5. passes the rejected access token through the 401 recovery path, so a token replaced while
   waiting is used rather than refreshed a second time
6. serialises cooperating app copies with a cancellation-aware cross-process `flock`

The lock is advisory and Claude Code does not participate in it. Re-reading the exact Keychain
item immediately before writing narrows the remaining race with non-cooperating processes, but
cannot make that external compare-and-write atomic.

If refresh fails the last good numbers stay on screen, dimmed, with a note to run `claude`
once.

## Development

```sh
swift build
swift test

# print resolved windows and exit — handy for checking against /usage
./.build/debug/ClaudeUsage --dump
./.build/debug/ClaudeUsage --dump-codex

# drive the UI from a JSON file instead of the live endpoint
CLAUDE_USAGE_FIXTURE=/path/to/fixture.json ./.build/debug/ClaudeUsage
CODEX_USAGE_FIXTURE=/path/to/codex-fixture.json ./.build/debug/ClaudeUsage

# what the running app actually did — every fetch, outcome and wait
tail -f "$HOME/Library/Application Support/ClaudeUsage/usage.log"
```

The package and all targets compile in Swift 6 language mode. For XcodeGen setup, local checks,
and CI conventions, see [Development workflow](docs/development.md). For signing, sandboxing,
and notarization decisions, see
[Security and distribution decisions](docs/security-and-distribution.md).

The log matters more than it looks: the rate-limit windows are long enough that "waiting
exactly as instructed" and "silently wedged" are indistinguishable from the menu bar. It also
names the offending field on a decode failure rather than reporting Foundation's opaque *"the
data couldn't be read because it isn't in the correct format"*.

## Architecture

The repository follows a small feature-first layout: domain and policy code stays independent,
while macOS frameworks, persistence, authentication, and UI remain at the application edge.

```text
Sources/
├── UsageCore/
│   ├── Domain/              normalized usage values
│   ├── API/                 wire DTOs and domain mapping
│   ├── Polling/             pure persisted scheduling policy
│   └── Support/             time and ISO 8601 seams
└── ClaudeUsage/
    ├── App/                 composition root and process entry point
    ├── Features/Usage/
    │   ├── Data/            repository actor and persistence workflow
    │   └── Presentation/    observable state, formatting, and SwiftUI
    ├── Infrastructure/      API, OAuth, Keychain, logging, and app paths
    ├── Platform/            menu bar and launch-at-login adapters
    └── DeveloperTools/      deterministic screenshot harness
Tests/
├── UsageCoreTests/          domain, decoding, mapping, and polling policy
└── ClaudeUsageTests/        repository restart and infrastructure integration
```

`UsageCore` has no AppKit or SwiftUI dependency and is the default home for deterministic
business rules. `ClaudeUsage` composes those values with system adapters; `UsageStore` only owns
presentation state and scheduling triggers, while `UsageRepository` owns network and disk work.

## Screenshots

The images above are generated, never captured by hand, and refreshed by a pre-commit hook —
so a commit that changes the interface carries the matching images with it. Once per clone:

```sh
git config core.hooksPath .githooks
```

`.githooks/pre-commit` then re-renders and stages `docs/screenshots/` whenever the commit
touches Swift sources, `Package.swift` or `screenshots.sh`, and does nothing
at all otherwise — a README-only commit does not pay for a build. Bypass it with
`SKIP_SCREENSHOTS=1 git commit` or `git commit --no-verify`.

By hand, or from CI:

```sh
./screenshots.sh            # rewrite docs/screenshots/
./screenshots.sh --check    # fail if the committed PNGs are out of date
```

`--check` renders to a temp directory and diffs, so a UI change committed with the hook
bypassed shows up as a failure rather than as a quietly outdated README.

Under the hood it is `ClaudeUsage --screenshot <dir>`. The app puts the real `DropdownView` in
an `NSHostingView` inside an offscreen window and reads the layer back at 2×, so the picker,
the checkbox and the links are the actual controls rather than a mock-up, and the menu bar
chip comes from the same `GaugeRenderer` that draws the status item. Both are rendered twice,
once per appearance, and the README picks light or dark from `prefers-color-scheme`.

Output is byte-identical between runs — `git status` stays clean unless the UI actually
changed. Two things make that true:

- a fixture compiled into `Screenshots.swift` rather than live account data, so the numbers in
  the README are not anyone's real Claude or Codex usage
- an injected fixed `DateProvider` and a pinned `UTC` timezone, so "Resets in 2h 41m",
  reset labels such as "Resets Mon 09:00" are fixed instead of whatever the wall clock
  said at render time

It needs a window server, so run it on a logged-in Mac rather than over a bare SSH session; a
render that fails aborts the commit rather than letting a stale image through silently.
