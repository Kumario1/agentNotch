# agentNotch

A buttery-smooth macOS notch app that shows real usage limits for Claude Code,
Codex, and Cursor from local config dirs. Local-only, Apple Silicon, macOS 14+.

It sits over the notch: compact gauges collapsed, a dark card on hover with live
sessions and per-account limit bars.

## Multi-account (Claude)

List every Claude config dir in `~/.agentnotch.json`:

```json
{ "claude": ["~/.claude", "~/claude-work"] }
```

Each dir is one account (log in once per dir with `CLAUDE_CONFIG_DIR=... claude`).
In the expanded panel, use the account pills to browse limits, then **Switch** to
make the next plain `claude` run use that account's OAuth token.

**Caveats:** switching only affects newly started `claude` sessions; running sessions
keep their token. macOS may prompt for Keychain access. Multi-account use is subject
to Anthropic's terms of service.

## Run

```sh
swift run -c release
```

The app has no Dock icon (`.accessory` policy). Hover the notch to expand.

## Test

```sh
swift test
```
