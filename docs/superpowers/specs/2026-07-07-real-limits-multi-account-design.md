# Real limits + multi-account (Claude Code & Codex) — Design

**Goal:** replace guessed token caps with real limit data, shown per account, for Claude Code and Codex. Multiple accounts per product = multiple config dirs.

## Config

`~/.agentnotch.json` (optional):

```json
{ "claude": ["~/.claude", "~/claude-work"], "codex": ["~/.codex"] }
```

Missing file or key → defaults `["~/.claude"]` / `["~/.codex"]`. Each dir is one account. Tilde-expanded. Re-read only at launch.

## Claude provider (one instance per configured dir)

- **Credentials:** `<dir>/.credentials.json` → `claudeAiOauth.accessToken` / `expiresAt`; if the file is absent, fall back to the macOS Keychain generic password `Claude Code-credentials` (same JSON payload).
- **Label:** `oauthAccount.emailAddress` from `<dir>/.claude.json`; fall back to the dir name.
- **Fetch:** `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`, every 60s (URLSession, background queue). Response gives per-window utilization (0–100) and `resets_at` for the 5-hour and 7-day windows (plus 7-day Opus when present); parse leniently — unknown/missing windows are skipped.
- **Expired/invalid token (401 or `expiresAt` past):** account row shows "re-login needed". We never refresh tokens ourselves — refresh-token rotation could log the CLI out.

## Codex provider (one instance per configured dir)

- **Source:** session files `<dir>/sessions/YYYY/MM/DD/rollout-*.jsonl`. Turn events carry a `rate_limits` object: `primary` (≈5h window) and `secondary` (weekly), each with `used_percent`, `window_minutes`, `resets_in_seconds`.
- **Mechanism:** reuse the UsageEngine pattern — initial scan of recent files (mtime cutoff), DispatchSource watches on the day directory + active files, byte-offset incremental reads. Keep only the newest `rate_limits` snapshot and its event timestamp.
- **Label:** email claim from the `id_token` JWT in `<dir>/auth.json` (base64 decode payload, no verification); fall back to dir name.
- **Staleness:** data updates only while Codex runs; snapshot carries `asOf` and the UI shows "as of N min ago" when older than ~5 min. If a window has already reset since `asOf`, show 0%.

## Model

```swift
struct LimitWindow: Equatable { let name: String; let percent: Double; let resetsAt: Date? }
struct AccountUsage: Equatable, Identifiable {
    let id: String          // product + config dir
    let product: Product    // .claude | .codex
    let label: String       // email or dir name
    var windows: [LimitWindow]
    var asOf: Date?
    var lastActivity: Date?
    var status: String?     // "re-login needed", "no credentials", … — shown instead of bars
}
```

`UsageStore` publishes `accounts: [AccountUsage]` (plus the existing snapshot fields for last project). The existing JSONL token tailer is retained only for Claude activity detection (lastActivity/lastProject per dir); its cap-estimation display is removed.

## UI

- **Collapsed pill:** left gauge = most-recently-active Claude account's highest-utilization window; right gauge = same for Codex. Missing product → gauge hidden.
- **Expanded panel:** one row per account: product icon, label, one bar per window with % and reset countdown (`Text(timerInterval:)`), staleness/status line when applicable. Same rendering rules as today (Equatable rows, numericText transitions, publishes debounced).

## Errors

Any per-account failure (unreadable dir, bad JSON, network error) degrades to `status` text on that row only. No retries beyond the next poll tick. Nothing blocks the main thread.

## Testing

Extend `UsageEngineTests`: (1) parse a canned OAuth usage JSON → expected `LimitWindow`s; (2) parse a synthetic Codex `rate_limits` JSONL line → expected snapshot, and a newer line replaces an older one; (3) config file parsing with defaults.

## Explicitly skipped

Token refresh, config-dir auto-discovery, historical charts, live config reload, Codex network endpoint.
