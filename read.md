Yes — AgentPeek is a small macOS app that keeps Claude Code, Codex, Cursor, Hermes, and OpenCode in view from your Mac notch and menu bar. It's built by a solo developer (Bren) and launched fairly recently on Product Hunt. AgentPeek
The core idea: instead of alt-tabbing between terminals to babysit your coding agents, everything surfaces in the notch. You get live sessions, permission prompts, your 5-hour and 7-day token usage, and your local dev servers, all at a glance. When an agent needs approval, the request appears right in the notch and you can respond with a single keystroke: ⌘A to allow, ⌘N to deny, or ⌥A to always allow. AgentPeekAat
A few practical details:
Setup is basically zero. On first launch it installs small hooks for each agent, and every new session picks them up automatically — works whether you run claude in a terminal or use the desktop apps, since they share the same session state on disk. AgentPeek
It's local-first. Session transcripts, diffs, prompts, and token usage never leave your Mac — no telemetry or accounts. AgentPeek
Pricing: free trial for a few days, then a one-time $15 for Apple silicon Macs with future updates included, no subscription. Requires macOS 14+. AgentPeek
It also does some nice extras: it watches ports 3000–9999 for dev servers, labels frameworks like Next.js and Vite, and lets you open, copy, or cleanly stop a server in one click, plus tool-call timelines per session and stuck-session/budget alerts. AgentPeek
Given how much you're running Claude Code for GGC and your ML projects, it's honestly a pretty good fit for your workflow — cheap one-time cost, and the token-budget countdown alone is handy if you're bumping against 5-hour limits during sprint work. Were you thinking of trying it, or just curious what it was?i want to build the same exact thing, first of all when i tried it out it was very janky. it's very laggy and not smooth. So i want to fix all those problems and do it just so i can use it locally.Architected performant Swift implementation prioritizing efficiency over janky overlaysArchitected performant Swift implementation prioritizing efficiency over janky overlaysGood instinct — this is actually a very buildable weekend-to-two-week project, and the jank you felt almost certainly comes from fixable architectural choices. Let me break down how the thing actually works under the hood and where the smoothness gets won or lost.
How AgentPeek-style apps work
There's no magic API. Claude Code and Codex write their session state to disk in known locations, and the app just watches those files:

Claude Code: ~/.claude/projects/<project-hash>/*.jsonl — every session is an append-only JSONL transcript containing user messages, assistant replies, tool calls, and token usage per message. Hooks are configured in ~/.claude/settings.json.
Codex: ~/.codex/sessions/ with a similar rollout-file structure.
Permission prompts: Claude Code's PreToolUse hook can block and return a JSON decision (allow/deny). So the flow is: hook script fires → sends the request over a local Unix socket to your app → your notch UI shows Allow/Deny → user hits ⌘A → app replies over the socket → hook script prints the decision JSON and Claude Code proceeds. That's the whole "approve from the notch" trick.
Dev servers: just enumerate listening TCP ports (via lsof-style syscalls or proc_pidinfo) on 3000–9999 and map PIDs to working directories.
Token windows: sum the usage fields from transcript entries, bucketed into rolling 5-hour / 7-day windows.

Where the jank comes from, and how you beat it
The lag you noticed almost always traces to one of four sins:

Polling instead of file events. If you re-read and re-parse entire JSONL transcripts on a timer, long sessions (which can hit tens of MB) will stutter everything. Fix: use DispatchSource.makeFileSystemObjectSource or FSEvents to get notified on writes, keep a byte offset per file, and only parse the newly appended bytes. Incremental tailing makes even huge sessions free.
Parsing on the main thread. All file IO and JSON decoding goes on a background queue; the main thread only ever receives a tiny, already-computed view model (session name, state enum, last activity string, counters). Debounce updates to ~10–15/sec max — agent output can burst hundreds of lines per second and you don't need to render each one.
SwiftUI doing too much work per frame. The notch pill animation should be a single NSPanel (borderless, non-activating, .statusBar window level, positioned over the notch) with the expand/collapse driven by Core Animation or a carefully scoped SwiftUI animation. The killer mistake is having the whole panel's view tree re-evaluate on every session update while an animation is in flight. Keep the pill and the expanded panel as separate view hierarchies, and make session rows Equatable so unchanged rows don't re-render.
Not being native at all. If any part of it is Electron/web-view, the notch physically cannot feel smooth. Pure Swift + AppKit window management + SwiftUI content is the right stack, and since it's Apple-silicon-only for personal use, you can target macOS 15 and ProMotion without compatibility guilt.

Suggested build order

Notch window shell — get a borderless panel that sits over the notch, expands on hover, collapses on mouse-out, buttery at 120Hz with placeholder content. Nail this first; it's the whole feel of the app.
Session watcher — incremental JSONL tailer for ~/.claude/projects, emitting a SessionState (executing / waiting / idle / done) derived from the last few events and file mtime.
Hook + socket for permissions — a tiny shell/Swift hook binary registered in settings.json, Unix socket into the app, keyboard shortcuts to respond.
Token usage + dev server list — both are simple once the watcher exists.
Codex/Cursor support later if you ever care.

One nice advantage of building it yourself: you can define "stuck" properly — e.g., surface elapsed-time-in-current-tool-call so a 12-minute legitimately-running command looks different from a wedged one, which was a gap people called out in the original.
This is exactly the kind of project where you'd want an agent working directly in an Xcode project rather than pasting Swift back and forth in chat:Recommended apps and extensionsBrowse allClaude Code for desktopLet Claude scaffold and iterate on the Swift notch app right in your repo.Want me to start by writing the notch window shell (the NSPanel setup + hover expand/collapse), or the JSONL session watcher? The window shell is the part with the most non-obvious AppKit tricks, so that's where I'd start if you want the smoothness solved first.
