# Security and distribution decisions

Claude Usage is distributed directly with a Developer ID Application certificate. It uses the Hardened Runtime and
notarization, but it does not currently enable the macOS App Sandbox.

## Sandbox decision

The app reads and may rotate the OAuth credential stored by Claude Code in the user's login Keychain. Claude Code and
Claude Usage do not share an Apple development team, Keychain access group, App Group, or another supported sandbox
coordination mechanism. Enabling `com.apple.security.app-sandbox` would therefore prevent the app from using that
existing cross-application Keychain item reliably.

This is a deliberate compatibility decision for direct distribution, not a general exemption from least privilege.
Revisit it if Claude Code exposes a supported credential broker, shared access group, or user-mediated authorization
flow. A read-only design that never rotates Claude Code's credential would reduce risk but would not by itself solve
the sandbox access-group boundary.

## Codex authentication boundary

| Concern | Behavior |
| --- | --- |
| Protocol | `codex app-server` over local stdin/stdout |
| Credentials | Owned and refreshed by Codex |
| Token access | Claude Usage never reads `~/.codex/auth.json` or Codex Keychain items |
| Login | No browser or device login is started by Claude Usage |
| Executable lookup | ChatGPT/Codex app bundles, standard CLI paths, then `PATH` |
| Override | `CODEX_USAGE_CODEX_PATH` |

The app launches the executable directly with `Process`; it does not invoke a shell. JSON-RPC
output is capped at 1 MiB, stderr is discarded, and the process is terminated after a response,
timeout, or cancellation. A missing or expired sign-in becomes a dropdown status and uses
persisted backoff.

## Release entitlements

[`Configuration/ClaudeUsage.release.entitlements`](../Configuration/ClaudeUsage.release.entitlements) is intentionally
empty. The release requests:

- no App Sandbox exceptions;
- no Hardened Runtime exceptions;
- no debugger attachment (`com.apple.security.get-task-allow`);
- no camera, microphone, location, contacts, files, Apple Events, or incoming-network access.

An unsandboxed app does not use `com.apple.security.network.client`; outbound network access is available without that
entitlement. The app still runs under the Hardened Runtime and macOS protections such as code signing, library
validation, System Integrity Protection, TCC, and Keychain access control. Add an entitlement only when a concrete
feature needs it, document why, and test the signed release build.

The app's stable Developer ID signature is security-relevant: the user's Keychain authorization is associated with the
signed client requirement. Do not distribute ad-hoc-signed production builds.

## Release process

The production path is [`Scripts/release.sh`](../Scripts/release.sh). It:

1. builds arm64 and x86_64 release executables and combines them into a universal binary;
2. assembles a fresh app bundle in an isolated staging directory;
3. signs nested code from the inside out, then signs the app last;
4. applies the Hardened Runtime, a secure timestamp, and the explicit release entitlements;
5. verifies the signature and packages the app with `ditto`;
6. optionally submits the zip with `notarytool`, staples the accepted ticket to the app, verifies it, and rebuilds the
   zip so the archive contains the stapled app.

The signing identity is not a secret. Pass it through `--identity` or `DEVELOPER_ID_APPLICATION`:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Example Name (TEAMID)" \
  Scripts/release.sh
```

Notarization credentials are secrets and must not be stored in the repository or environment files. Store them once in
the login Keychain, then pass only the profile name:

```bash
xcrun notarytool store-credentials "claude-usage-notary" \
  --apple-id "developer@example.com" \
  --team-id "TEAMID"

Scripts/release.sh \
  --identity "Developer ID Application: Example Name (TEAMID)" \
  --notary-profile "claude-usage-notary"
```

The script emits unnotarized artifacts only when notarization is explicitly omitted, and prints a warning in that
case. Public releases should always include `--notary-profile` and should be downloaded and launched on a clean Mac or
VM to exercise Gatekeeper and the quarantine path.

## Adding nested code

The release script discovers Mach-O files and nested `.framework`, `.xpc`, `.appex`, and `.app` bundles and signs them
before the outer app. A new nested executable that needs its own entitlements must have those entitlements added to the
release design before shipping; do not reuse the main app's entitlements and do not use `codesign --deep` to sign.
