# agentNotch

A buttery-smooth macOS notch app that shows real usage limits for Claude Code,
Codex, and Cursor from local config dirs. Local-only, macOS 14+.

It sits over the notch: compact gauges collapsed, a dark card on hover with live
sessions and per-account limit bars.

## Install (recommended)

1. Build the app bundle:

```sh
./scripts/package-app.sh
```

2. Copy to Applications and open once:

```sh
cp -R dist/agentNotch.app /Applications/
open -a agentNotch
```

On first launch the app discovers Claude / Codex / Cursor account dirs under your
home folder, writes `~/.agentnotch.json`, and starts watching them. Enable
**Launch at login** in Settings (gear in the expanded notch) if you want it every
session. Use the app from `/Applications` (not from the DMG). macOS may ask you
to allow agentNotch under **System Settings → General → Login Items** — Settings
shows that status and can open the pane for you.

Each macOS user account has its own home directory and Keychain — install the
`.app` once in `/Applications`, then each user opens it once so their accounts
are discovered.

### Ship to other Macs

```sh
# 1. Package
./scripts/package-app.sh

# 2. Sign (+ notarize when credentials are set)
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/sign-and-notarize.sh dist/agentNotch.app

# Optional notarization env:
#   APPLE_ID=you@example.com APPLE_TEAM_ID=XXXXXXXXXX APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx

# 3. DMG for drag-to-Applications
./scripts/make-dmg.sh
```

Without notarization, other Macs will Gatekeeper-block the app. Ad-hoc local
signing only: `SIGN_IDENTITY='-' ./scripts/sign-and-notarize.sh dist/agentNotch.app`.

## Multi-account (Claude)

On first launch, agentNotch auto-discovers:

- `~/.claude` if present
- any other home folder that contains `.credentials.json` or `.claude.json`
  (e.g. `~/claude-work`)
- `~/.codex` / `~/.cursor` when those dirs exist

You can still edit the list in Settings or in `~/.agentnotch.json`:

```json
{ "claude": ["~/.claude", "~/claude-work"] }
```

Each dir is one account (log in once per dir with `CLAUDE_CONFIG_DIR=... claude`).
In the expanded panel, use the account pills to browse limits, then **Switch** to
make the next plain `claude` run use that account's OAuth token.

**Caveats:** switching only affects newly started `claude` sessions; running sessions
keep their token. macOS may prompt for Keychain access. Multi-account use is subject
to Anthropic's terms of service.

## Dev run

```sh
swift run -c release
```

The app has no Dock icon (`.accessory` / `LSUIElement`). Hover the notch to expand.

## Test

```sh
swift test
```
