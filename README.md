# agentNotch

A buttery-smooth macOS notch app that shows Claude Code token usage against the
rolling **5-hour** and **7-day** limit windows. Local-only, Apple Silicon, macOS 14+.

It reads `~/.claude/projects/**/*.jsonl` incrementally (file-system events, no polling)
and sits over the notch: two capsule gauges collapsed, a dark card on hover.

## Run

```sh
swift run -c release
```

The app has no Dock icon (`.accessory` policy). Hover the notch to expand. Token caps
are rough estimates in `Sources/agentNotch/UsageEngine.swift` — tune them to your plan.

## Test

```sh
swift test
```
