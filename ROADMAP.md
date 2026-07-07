# agentNotch — Roadmap

**Goal:** a buttery-smooth macOS notch app that surfaces coding-agent sessions, usage limits, and permission prompts — local-only, Apple Silicon, macOS 14+. No Electron, no polling, no jank.

**Non-goals (for now):** dev-server port watcher · packaged `.app` distribution.

---

## Step 0 — Project scaffold (done)

Swift Package Manager executable `agentNotch`; AppKit lifecycle with `.accessory` activation policy; `swift build` / `swift run`.

---

## Step 1 — Notch window shell (done)

`NSPanel` over the physical notch; hover expand/collapse with grace debounce; spring-morphed `NotchShape`; separate collapsed/expanded content hierarchies; no frame animation jank.

---

## Step 2 — Usage engine (done)

Incremental JSONL tailer for `~/.claude/projects/**/*.jsonl`; rolling 5h/7d windows; debounced publishes; background-only parsing.

---

## Step 3 — Notch UI (done)

Collapsed pill gauges; expanded glass panel; `@Observable` store; `.contentTransition(.numericText())`.

---

## Step 4 — Polish & verification (done)

Multi-screen reposition; unit tests for parsing/window math; `swift build -c release` clean.

---

## Step 5 — Real limits, multi-account (done)

Claude via OAuth usage endpoint; Codex via `rate_limits` in session rollouts; per-account cards; collapsed wings show most-recently-active account. Spec: `docs/superpowers/specs/2026-07-07-real-limits-multi-account-design.md`.

---

## Step 6 — Live sessions (done)

`SessionEngine` tails Claude + Codex transcripts; active/inactive from terminal events; expanded panel session list with product filters and detail view.

---

## Step 7 — Settings

**Plan**
- Writable `~/.agentnotch.json`: Claude/Codex/Cursor config dirs, approval toggles, launch-at-login.
- Standard `NSWindow` settings sheet (gear icon in expanded notch); not embedded in the notch panel.
- Sections: watched dirs (add/remove), approval hook install status, launch at login (`SMAppService`), about footer.
- Dir changes apply on next launch (documented in-UI).

**Acceptance:** gear opens settings; toggles persist; hook install/uninstall reflected in status labels.

---

## Step 8 — Notch approvals (Claude end-to-end)

**Plan**
- `agentnotch-hook` executable: reads hook stdin JSON, forwards to app over `~/.agentnotch/approvals.sock`, blocks for decision, prints product-correct stdout JSON. Fail-open if app is down.
- `ApprovalServer` in app: publish `pendingApprovals`, await user decision, always-allow allowlist (`~/.agentnotch/always-allow.json`).
- Claude: additive `PreToolUse` entry in `~/.claude/settings.json` (preserves existing hooks).
- Cursor: additive `beforeShellExecution` + `preToolUse` in `~/.cursor/hooks.json` (best-effort; deny reliable, allow/ask upstream-limited).
- UI: bouncing notch when pending; `ApprovalCard` with Allow / Always Allow / Deny; ⌘A / ⌥A / ⌘N while panel is key.

**Acceptance:** Claude tool call blocks until notch decision; always-allow skips future matching tools; deny stops the tool.

---

## Step 9 — Cursor integration

**Plan**
- `Product.cursor`; `CursorTile` branding; collapsed wings show two most-recently-active accounts across all products.
- `SessionEngine` scans `~/.cursor/projects/*/agent-transcripts/**/*.jsonl`; `SessionParsing.applyCursor`.
- `CursorAccountProvider`: presence + last-activity status, plus real current-period usage
  when signed in (reads `cursorAuth/accessToken` from Cursor's `state.vscdb` and calls
  `api2.cursor.sh/.../GetCurrentPeriodUsage`; included-budget remaining % + reset date).
- Product filter chip for Cursor in expanded panel.

**Acceptance:** active Cursor agent sessions appear in the notch list; Cursor account row shows last activity and included-usage remaining.

---

## Later (explicitly deferred)

Dev-server port watcher (3000–9999) · tool-call timelines per session · stuck-session alerts · packaged `.app` with bundled hook binary · Codex end-to-end approvals.

## Step 6 — Claude account switching (done)

Switch the live Claude Code OAuth credential from the expanded notch panel when you
have multiple dirs in `~/.agentnotch.json`. Account pills browse per-account limits;
**Switch** writes the chosen account's token to the global Keychain item (and mirrors
`~/.claude/.credentials.json` when present). Only new `claude` sessions pick up the
swap. Implementation: `Sources/agentNotch/ClaudeAccountSwitcher.swift`.
