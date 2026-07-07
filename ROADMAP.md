# agentNotch — Roadmap

**Goal (MVP):** a buttery-smooth macOS notch app that displays Claude Code token usage against the 5-hour and 7-day limit windows. Local-only, Apple Silicon, macOS 14+. No Electron, no polling, no jank.

**Non-goals (for MVP):** permission prompts/hooks, dev-server watching, Codex/Cursor support, session timelines. Each is additive later; none affect the core architecture.

---

## Step 0 — Project scaffold

**Plan**
- Swift Package Manager executable target `agentNotch` (no Xcode project needed; `swift build` / `swift run` from terminal).
- `Package.swift`: platform `.macOS(.v14)`, single executable target.
- AppKit lifecycle without a storyboard: `main.swift` creates `NSApplication`, sets an `AppDelegate`, activation policy `.accessory` (no Dock icon, no menu bar takeover).
- File layout (keep it to 5 files):
  - `Sources/agentNotch/main.swift` — entry + AppDelegate
  - `Sources/agentNotch/NotchPanel.swift` — the window shell
  - `Sources/agentNotch/UsageEngine.swift` — JSONL tailer + rolling windows
  - `Sources/agentNotch/NotchView.swift` — SwiftUI content (pill + expanded)
  - `Sources/agentNotch/Models.swift` — tiny value types

**Acceptance:** `swift build` succeeds; `swift run` shows a blank panel over the notch.

---

## Step 1 — Notch window shell (the "feel" of the app)

This is where AgentPeek was janky. Nail this before any data exists.

**Plan**
- `NSPanel` subclass: `.borderless`, `.nonactivatingPanel`, `isOpaque = false`, clear background, `hasShadow = false` when collapsed.
- Window level `.statusBar`; collection behavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` so it survives Spaces/fullscreen.
- Geometry from `NSScreen.main.safeAreaInsets.top` and `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` to compute the physical notch rect; fall back to a fixed 200×32 centered rect on non-notch Macs (so it still works on external displays).
- Collapsed state: panel exactly covers the notch (invisible content, or a thin usage sliver below the notch). Expanded state: grows downward/outward to ~360×150 with a rounded-bottom "notch continuation" shape.
- Hover: `NSTrackingArea` on the content view; expand on `mouseEntered`, collapse on `mouseExited` with a ~150ms grace debounce so it doesn't flicker.
- Animation: animate the **panel frame** with `NSAnimationContext` (spring-ish timing, 0.25s) and let SwiftUI content fade/scale inside. Pill and expanded panel are **separate view hierarchies** — never re-evaluate one while animating the other.

**Pitfalls to avoid (the jank list)**
- Don't recreate the panel on expand/collapse — one panel, resize it.
- Don't put file IO or parsing anywhere near this code.
- Don't let session updates land mid-animation: gate view-model publishes behind the animation state or just let debouncing handle it.

**Acceptance:** hover expand/collapse feels instant and smooth at 120Hz with placeholder text; no flicker on rapid hover in/out.

---

## Step 2 — Usage engine (incremental JSONL tailer)

**Plan**
- Source of truth: `~/.claude/projects/**/*.jsonl`. Each assistant line has `message.usage` (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`) and a `timestamp`.
- On launch (background queue, `utility` QoS):
  1. Enumerate project dirs; skip files with mtime older than 7 days (they can't contribute to any window).
  2. Parse qualifying files line-by-line with a streaming reader (never load a whole file into memory); collect `(Date, tokens)` events into a time-sorted buffer.
- Live updates: one `DispatchSource.makeFileSystemObjectSource` per project directory (catches new session files) + per-active-file `.write` sources. Keep a **byte offset per file**; on write events parse only appended bytes. Handle partial trailing lines (buffer until newline).
- Rolling windows: 5-hour window anchored to the first event after the last reset (Claude's window starts at first message), plus a plain 7-day rolling sum. Recompute is a cheap prune-and-sum over the in-memory event buffer.
- Publish: a single small `UsageSnapshot` struct (5h tokens, 7d tokens, window start, next reset date) to the main thread, debounced to max ~4 publishes/sec. The UI never sees raw events.
- Limits: Anthropic doesn't publish token caps, so caps are user-tunable constants at the top of `UsageEngine.swift` (default: rough Max-plan estimates). Display is % of cap + absolute tokens, so wrong caps still give useful signal.

**Acceptance:** run `claude` in a terminal, send a message, watch numbers move within ~1s; CPU stays ~0% idle; a 50MB transcript causes no UI stutter.

---

## Step 3 — Notch UI (display the limits smoothly)

**Plan**
- Collapsed pill: two tiny horizontal capsule gauges flanking the notch (left = 5h, right = 7d), color-shifting green→amber→red. Nothing animates unless a value changes.
- Expanded panel: dark glass card with
  - 5h window: progress bar, tokens used / cap, countdown to reset (`Text(timerInterval:)` — SwiftUI drives it, zero timers of ours)
  - 7d window: same, minus countdown
  - last-activity line (most recent session project name + relative time)
- All rows `Equatable`; view model is one `@Observable` snapshot object so unchanged subtrees don't re-render.
- Number changes animate with `.contentTransition(.numericText())` — cheap and pretty.

**Acceptance:** values update live without any visible hitch while hovering/animating.

---

## Step 4 — Polish & verification

**Plan**
- Debounce audit: burst-append 1000 lines to a test JSONL and confirm ≤ a handful of UI publishes.
- Multi-screen: pick the screen with a notch; re-position on `NSApplication.didChangeScreenParametersNotification`.
- Self-check: a small `test_usage.swift`-style runnable check (or `swift test` with one test) that feeds synthetic JSONL lines through the tailer and asserts window sums — the one check that fails if parsing/window math breaks.
- Run instructions in README: `swift run -c release`.

**Acceptance:** `swift build -c release` clean; self-check passes; app runs and displays real usage.

---

## Later (explicitly deferred)
Permission prompts via PreToolUse hook + Unix socket · dev-server port watcher · per-session status list · launch-at-login · Codex support.

## Step 5 — Real limits, multi-account (done)

Real per-account limit data replaces cap estimation: Claude via the OAuth usage
endpoint (per config dir in `~/.agentnotch.json`, default `~/.claude`), Codex via
`rate_limits` snapshots in `~/.codex/sessions` rollouts. One card per account in
the expanded panel; collapsed wings show the most-recently-active account per
product. Spec: `docs/superpowers/specs/2026-07-07-real-limits-multi-account-design.md`.
