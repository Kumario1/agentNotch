# Real Limits + Multi-Account Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Show real usage-limit data (utilization % + reset times) per account for Claude Code and Codex in the notch UI, replacing guessed token caps.

**Architecture:** Per config dir, a provider produces an `AccountUsage` value: Claude via the Anthropic OAuth usage endpoint (60s poll), Codex via `rate_limits` snapshots in local session JSONL files (15s incremental scan). A small `LimitsEngine` merges provider updates and publishes `[AccountUsage]` to the existing `UsageStore`; the UI renders one row per account. The existing token tailer (`UsageEngine`) stays only for the last-project footer.

**Tech Stack:** Swift 5.9 SPM executable, macOS 14+, Foundation (URLSession, JSONSerialization, DispatchSourceTimer), SwiftUI/AppKit. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-07-real-limits-multi-account-design.md`

## Global Constraints

- macOS 14+, Apple Silicon; SPM only, zero external dependencies.
- Never block the main thread: all IO/network on utility-QoS queues; publishes hop to main.
- Never refresh OAuth tokens (rotation could log the CLI out). Expired/401 → status `"re-login needed"`.
- Per-account failures degrade to a `status` string on that row; never crash, never retry beyond the next tick.
- Parse leniently: unknown/missing JSON fields skip the window/line, never throw.
- The repo is not yet a git repo — Task 1 runs `git init`. Commit at the end of every task with the message given.
- Build with `swift build`; test with `swift test`. Both must be clean at the end of every task.

## File Structure

- `Sources/agentNotch/Models.swift` — modify: add `Product`, `LimitWindow`, `AccountUsage`, `AppConfig`, shared ISO parser; `UsageStore.accounts`.
- `Sources/agentNotch/ClaudeLimits.swift` — create: pure Claude parsers + `ClaudeAccountProvider` (poller).
- `Sources/agentNotch/CodexLimits.swift` — create: pure Codex parsers + `CodexAccountProvider` (session scanner).
- `Sources/agentNotch/LimitsEngine.swift` — create: builds providers from config, merges, publishes.
- `Sources/agentNotch/NotchView.swift` — modify: account rows, product tiles, percent bars.
- `Sources/agentNotch/NotchPanel.swift` — modify: dynamic expanded height by account count.
- `Sources/agentNotch/main.swift` — modify: wire `LimitsEngine`.
- `Tests/agentNotchTests/LimitsTests.swift` — create: parser + config tests.

---

### Task 1: git init, models, config

**Files:**
- Modify: `Sources/agentNotch/Models.swift`
- Test: `Tests/agentNotchTests/LimitsTests.swift` (create)

**Interfaces:**
- Produces: `Product` (`.claude`/`.codex`), `LimitWindow{name:String, percent:Double, resetsAt:Date?}`, `AccountUsage{id, product, label, windows, asOf, lastActivity, status}`, `UsageStore.accounts: [AccountUsage]`, `AppConfig{claudeDirs:[URL], codexDirs:[URL]}` with `AppConfig.parse(_ data: Data?) -> AppConfig` and `AppConfig.load() -> AppConfig`, `parseISO8601(_ s: String) -> Date?`.

- [x] **Step 1: Initialize git and commit the baseline**

```bash
cd /Users/princekumar/Documents/agentNotch
git init
printf '.build/\n.DS_Store\n' > .gitignore
git add -A
git commit -m "chore: baseline before real-limits work"
```

- [x] **Step 2: Write failing tests for config parsing and ISO helper**

Create `Tests/agentNotchTests/LimitsTests.swift`:

```swift
import XCTest
@testable import agentNotch

final class LimitsTests: XCTestCase {

    // MARK: Config

    func testConfigDefaults() {
        let c = AppConfig.parse(nil)
        XCTAssertEqual(c.claudeDirs.map(\.lastPathComponent), [".claude"])
        XCTAssertEqual(c.codexDirs.map(\.lastPathComponent), [".codex"])
    }

    func testConfigCustomDirsAndTildeExpansion() {
        let json = Data(#"{"claude": ["~/.claude", "~/claude-work"], "codex": ["~/.codex"]}"#.utf8)
        let c = AppConfig.parse(json)
        XCTAssertEqual(c.claudeDirs.count, 2)
        XCTAssertFalse(c.claudeDirs[1].path.contains("~"), "tilde must be expanded")
        XCTAssertTrue(c.claudeDirs[1].path.hasSuffix("/claude-work"))
    }

    func testConfigMalformedFallsBackToDefaults() {
        let c = AppConfig.parse(Data("not json".utf8))
        XCTAssertEqual(c.claudeDirs.map(\.lastPathComponent), [".claude"])
    }

    // MARK: ISO helper

    func testParseISO8601BothVariants() {
        XCTAssertNotNil(parseISO8601("2026-07-07T10:00:00.000Z"))
        XCTAssertNotNil(parseISO8601("2026-07-07T10:00:00Z"))
        XCTAssertNil(parseISO8601("yesterday"))
    }
}
```

- [x] **Step 3: Run tests to verify they fail**

Run: `swift test --filter LimitsTests`
Expected: compile error — `AppConfig` / `parseISO8601` not defined.

- [x] **Step 4: Add models, config, ISO helper to Models.swift**

Append to `Sources/agentNotch/Models.swift`:

```swift
// MARK: - Real-limit models (per-account, per-window)

enum Product: String, Equatable { case claude, codex }

struct LimitWindow: Equatable {
    let name: String        // "5H", "7D", "OPUS", "WEEK"
    let percent: Double     // 0–100 as reported by the source
    let resetsAt: Date?
}

struct AccountUsage: Equatable, Identifiable {
    let id: String          // "<product>:<config dir path>"
    let product: Product
    let label: String       // account email, or dir name as fallback
    var windows: [LimitWindow] = []
    var asOf: Date? = nil          // when the source last reported
    var lastActivity: Date? = nil  // most recent CLI activity for this account
    var status: String? = nil      // shown instead of bars when non-nil
}

// Shared lenient ISO-8601 parsing (sources vary on fractional seconds).
private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()
func parseISO8601(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

// MARK: - Config: which config dirs are accounts

struct AppConfig: Equatable {
    var claudeDirs: [URL]
    var codexDirs: [URL]

    static func parse(_ data: Data?) -> AppConfig {
        var claude = ["~/.claude"], codex = ["~/.codex"]
        if let data,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            claude = obj["claude"] ?? claude
            codex = obj["codex"] ?? codex
        }
        func urls(_ paths: [String]) -> [URL] {
            paths.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
        }
        return AppConfig(claudeDirs: urls(claude), codexDirs: urls(codex))
    }

    static func load() -> AppConfig {
        let path = NSString(string: "~/.agentnotch.json").expandingTildeInPath
        return parse(FileManager.default.contents(atPath: path))
    }
}
```

And add the accounts array to `UsageStore` (replace the existing class body):

```swift
// One observable holder shared by the SwiftUI hierarchies. Unchanged subtrees don't re-render.
@Observable final class UsageStore {
    var snapshot = UsageSnapshot()
    var accounts: [AccountUsage] = []
}
```

- [x] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LimitsTests`
Expected: 4 tests PASS. Also run `swift test` (all) — the existing `UsageEngineTests` must still pass.

- [x] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: account/limit models, config file, ISO helper"
```

---

### Task 2: Claude parsers (pure, tested)

**Files:**
- Create: `Sources/agentNotch/ClaudeLimits.swift`
- Test: `Tests/agentNotchTests/LimitsTests.swift` (extend)

**Interfaces:**
- Consumes: `LimitWindow`, `parseISO8601` from Task 1.
- Produces: `ClaudeCredentials{accessToken:String, expiresAt:Date?}`, `ClaudeLimits.credentials(from: Data) -> ClaudeCredentials?`, `ClaudeLimits.windows(fromUsageResponse: Data) -> [LimitWindow]`, `ClaudeLimits.email(fromClaudeJSON: Data) -> String?`.

- [x] **Step 1: Write failing tests**

Append to `Tests/agentNotchTests/LimitsTests.swift` (inside the class):

```swift
    // MARK: Claude parsers

    func testClaudeCredentialsParsing() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"r","expiresAt":1783000000000,"subscriptionType":"max"}}"#.utf8)
        let c = ClaudeLimits.credentials(from: json)
        XCTAssertEqual(c?.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(c?.expiresAt, Date(timeIntervalSince1970: 1_783_000_000))
        XCTAssertNil(ClaudeLimits.credentials(from: Data("{}".utf8)))
    }

    func testClaudeUsageResponseParsing() {
        let json = Data("""
        {"five_hour":{"utilization":12.5,"resets_at":"2026-07-07T15:00:00Z"},
         "seven_day":{"utilization":40,"resets_at":"2026-07-12T00:00:00.000Z"},
         "seven_day_opus":{"utilization":5,"resets_at":null},
         "future_unknown_window":{"weird":true}}
        """.utf8)
        let w = ClaudeLimits.windows(fromUsageResponse: json)
        XCTAssertEqual(w.map(\.name), ["5H", "7D", "OPUS"])
        XCTAssertEqual(w[0].percent, 12.5)
        XCTAssertEqual(w[0].resetsAt, parseISO8601("2026-07-07T15:00:00Z"))
        XCTAssertEqual(w[1].percent, 40)
        XCTAssertNil(w[2].resetsAt)
        XCTAssertEqual(ClaudeLimits.windows(fromUsageResponse: Data("[]".utf8)), [])
    }

    func testClaudeEmailParsing() {
        let json = Data(#"{"oauthAccount":{"emailAddress":"me@example.com"},"otherStuff":1}"#.utf8)
        XCTAssertEqual(ClaudeLimits.email(fromClaudeJSON: json), "me@example.com")
        XCTAssertNil(ClaudeLimits.email(fromClaudeJSON: Data("{}".utf8)))
    }
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LimitsTests`
Expected: compile error — `ClaudeLimits` not defined.

- [x] **Step 3: Implement parsers**

Create `Sources/agentNotch/ClaudeLimits.swift`:

```swift
import Foundation

struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date?
}

// Pure parsers for Claude Code's on-disk/OAuth JSON shapes. Lenient by design:
// anything missing or unrecognized returns nil / is skipped, never throws.
enum ClaudeLimits {

    // <dir>/.credentials.json (also the exact payload of the "Claude Code-credentials"
    // Keychain item). expiresAt is epoch milliseconds.
    static func credentials(from data: Data) -> ClaudeCredentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expires)
    }

    // GET api.anthropic.com/api/oauth/usage response. Known windows only, fixed order.
    static func windows(fromUsageResponse data: Data) -> [LimitWindow] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let known: [(key: String, name: String)] = [
            ("five_hour", "5H"), ("seven_day", "7D"), ("seven_day_opus", "OPUS"),
        ]
        return known.compactMap { k in
            guard let w = obj[k.key] as? [String: Any],
                  let pct = w["utilization"] as? Double else { return nil }
            let resets = (w["resets_at"] as? String).flatMap(parseISO8601)
            return LimitWindow(name: k.name, percent: pct, resetsAt: resets)
        }
    }

    // <dir>/.claude.json — only the account email is interesting.
    static func email(fromClaudeJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = obj["oauthAccount"] as? [String: Any] else { return nil }
        return acct["emailAddress"] as? String
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LimitsTests`
Expected: all PASS.

- [x] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: Claude credential/usage/email parsers"
```

---

### Task 3: ClaudeAccountProvider (poller)

**Files:**
- Modify: `Sources/agentNotch/ClaudeLimits.swift` (append)

**Interfaces:**
- Consumes: `ClaudeLimits` parsers (Task 2), `AccountUsage`/`Product` (Task 1).
- Produces: `ClaudeAccountProvider(dir: URL, onUpdate: @escaping (AccountUsage) -> Void)` with `func start()`. Calls `onUpdate` on its own utility queue, only when the value changed. Account id is `"claude:<dir.path>"`.

No unit test — this class is IO/network glue; parsers were tested in Task 2. Verify by build + manual run in Task 7.

- [x] **Step 1: Implement the provider**

Append to `Sources/agentNotch/ClaudeLimits.swift`:

```swift
// Polls the OAuth usage endpoint for one Claude config dir every 60s.
// ponytail: no token refresh ever — expired/401 shows "re-login needed" instead.
final class ClaudeAccountProvider {
    private let dir: URL
    private let onUpdate: (AccountUsage) -> Void
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var last: AccountUsage?

    init(dir: URL, onUpdate: @escaping (AccountUsage) -> Void) {
        self.dir = dir
        self.onUpdate = onUpdate
        self.queue = DispatchQueue(label: "agentNotch.claude.\(dir.lastPathComponent)", qos: .utility)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 60)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    private var label: String {
        let f = dir.appendingPathComponent(".claude.json")
        if let d = FileManager.default.contents(atPath: f.path), let e = ClaudeLimits.email(fromClaudeJSON: d) {
            return e
        }
        return dir.lastPathComponent
    }

    // Newest mtime under <dir>/projects = this account's last CLI activity.
    private var lastActivity: Date? {
        let projects = dir.appendingPathComponent("projects")
        guard let en = FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: Date?
        for case let f as URL in en {
            if let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               newest == nil || m > newest! { newest = m }
        }
        return newest
    }

    private func credentials() -> ClaudeCredentials? {
        let f = dir.appendingPathComponent(".credentials.json")
        if let d = FileManager.default.contents(atPath: f.path), let c = ClaudeLimits.credentials(from: d) {
            return c
        }
        // Keychain fallback (default install stores the same JSON there).
        // ponytail: shell out to `security` — Security.framework is more code for the same bytes.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return ClaudeLimits.credentials(from: pipe.fileHandleForReading.readDataToEndOfFile())
    }

    private func poll() {
        var acc = AccountUsage(id: "claude:\(dir.path)", product: .claude, label: label)
        acc.lastActivity = lastActivity
        guard let creds = credentials() else {
            acc.status = "no credentials"
            publish(acc)
            return
        }
        if let e = creds.expiresAt, e < Date() {
            acc.status = "re-login needed"
            publish(acc)
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            self.queue.async {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 {
                    acc.status = "re-login needed"
                } else if let data, code == 200 {
                    let windows = ClaudeLimits.windows(fromUsageResponse: data)
                    if windows.isEmpty {
                        acc.status = "unexpected response"
                    } else {
                        acc.windows = windows
                        acc.asOf = Date()
                    }
                } else {
                    acc.status = "offline"
                }
                self.publish(acc)
            }
        }.resume()
    }

    // Suppress no-op updates so the UI never re-renders on identical data.
    // asOf changes every successful poll; compare everything else.
    private func publish(_ acc: AccountUsage) {
        var a = acc, b = last
        a.asOf = nil; b?.asOf = nil
        if a != b { last = acc; onUpdate(acc) }
    }
}
```

- [x] **Step 2: Verify it builds and all tests still pass**

Run: `swift build && swift test`
Expected: clean build, all tests PASS.

- [x] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: Claude account provider polling OAuth usage endpoint"
```

---

### Task 4: Codex parsers (pure, tested)

**Files:**
- Create: `Sources/agentNotch/CodexLimits.swift`
- Test: `Tests/agentNotchTests/LimitsTests.swift` (extend)

**Interfaces:**
- Consumes: `LimitWindow`, `parseISO8601` (Task 1).
- Produces: `CodexSnapshot{windows:[LimitWindow], asOf:Date}` (Equatable), `CodexLimits.snapshot(from line: Data) -> CodexSnapshot?`, `CodexLimits.email(fromAuthJSON: Data) -> String?`.

- [x] **Step 1: Write failing tests**

Append inside `LimitsTests`:

```swift
    // MARK: Codex parsers

    private func codexLine(ts: String, primaryPct: Double, secondaryPct: Double) -> Data {
        Data("""
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10}},"rate_limits":{"primary":{"used_percent":\(primaryPct),"window_minutes":300,"resets_in_seconds":3600},"secondary":{"used_percent":\(secondaryPct),"window_minutes":10080,"resets_in_seconds":86400}}}}
        """.utf8)
    }

    func testCodexSnapshotParsing() {
        let s = CodexLimits.snapshot(from: codexLine(ts: "2026-07-07T10:00:00.000Z", primaryPct: 12.5, secondaryPct: 40))
        XCTAssertEqual(s?.windows.map(\.name), ["5H", "WEEK"])
        XCTAssertEqual(s?.windows[0].percent, 12.5)
        XCTAssertEqual(s?.asOf, parseISO8601("2026-07-07T10:00:00.000Z"))
        // resets_in_seconds is relative to the line timestamp
        XCTAssertEqual(s?.windows[0].resetsAt, parseISO8601("2026-07-07T11:00:00.000Z"))
        XCTAssertEqual(s?.windows[1].resetsAt, parseISO8601("2026-07-08T10:00:00.000Z"))
    }

    func testCodexNonRateLimitLinesReturnNil() {
        XCTAssertNil(CodexLimits.snapshot(from: Data(#"{"timestamp":"2026-07-07T10:00:00Z","type":"event_msg","payload":{"type":"agent_message","message":"hi"}}"#.utf8)))
        XCTAssertNil(CodexLimits.snapshot(from: Data("not json".utf8)))
    }

    func testCodexNewerSnapshotWins() {
        let old = CodexLimits.snapshot(from: codexLine(ts: "2026-07-07T10:00:00.000Z", primaryPct: 10, secondaryPct: 10))!
        let new = CodexLimits.snapshot(from: codexLine(ts: "2026-07-07T11:00:00.000Z", primaryPct: 20, secondaryPct: 20))!
        let latest = [new, old].max { $0.asOf < $1.asOf }!
        XCTAssertEqual(latest.windows[0].percent, 20)
    }

    func testCodexEmailFromJWT() {
        // JWT with payload {"email":"me@example.com"} (unsigned, base64url segments)
        let payload = Data(#"{"email":"me@example.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let json = Data(#"{"tokens":{"id_token":"eyJhbGciOiJub25lIn0.\#(payload).sig"}}"#.utf8)
        XCTAssertEqual(CodexLimits.email(fromAuthJSON: json), "me@example.com")
        XCTAssertNil(CodexLimits.email(fromAuthJSON: Data("{}".utf8)))
    }
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LimitsTests`
Expected: compile error — `CodexLimits` not defined.

- [x] **Step 3: Implement parsers**

Create `Sources/agentNotch/CodexLimits.swift`:

```swift
import Foundation

struct CodexSnapshot: Equatable {
    var windows: [LimitWindow]
    var asOf: Date
}

// Pure parsers for Codex CLI's on-disk shapes (session rollout JSONL + auth.json).
enum CodexLimits {

    // A rollout line carrying payload.rate_limits → snapshot; anything else → nil.
    // primary ≈ 5h window, secondary ≈ weekly; named by window_minutes when present.
    static func snapshot(from line: Data) -> CodexSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any],
              let tsStr = obj["timestamp"] as? String,
              let ts = parseISO8601(tsStr) else { return nil }

        func window(_ key: String, fallback: String) -> LimitWindow? {
            guard let w = limits[key] as? [String: Any],
                  let pct = w["used_percent"] as? Double else { return nil }
            let name: String
            if let mins = w["window_minutes"] as? Double {
                name = mins <= 600 ? "5H" : "WEEK"
            } else {
                name = fallback
            }
            let resets = (w["resets_in_seconds"] as? Double).map { ts.addingTimeInterval($0) }
            return LimitWindow(name: name, percent: pct, resetsAt: resets)
        }

        let windows = [window("primary", fallback: "5H"), window("secondary", fallback: "WEEK")]
            .compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return CodexSnapshot(windows: windows, asOf: ts)
    }

    // auth.json → email claim from the id_token JWT payload (no signature check —
    // we're reading our own local file, not authenticating anyone).
    static func email(fromAuthJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let jwt = tokens["id_token"] as? String else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LimitsTests`
Expected: all PASS.

- [x] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: Codex rate-limit and auth.json parsers"
```

---

### Task 5: CodexAccountProvider (session scanner)

**Files:**
- Modify: `Sources/agentNotch/CodexLimits.swift` (append)

**Interfaces:**
- Consumes: `CodexLimits` parsers (Task 4), `AccountUsage`/`Product` (Task 1).
- Produces: `CodexAccountProvider(dir: URL, onUpdate: @escaping (AccountUsage) -> Void)` with `func start()`. Account id is `"codex:<dir.path>"`.

Deviation from spec noted: a 15s incremental timer scan instead of nested DispatchSource watches — sessions live in `sessions/YYYY/MM/DD/` and watching a rolling date tree is fiddly; reads stay byte-offset incremental so cost is ~zero. (`ponytail:` comment in code.)

- [x] **Step 1: Implement the provider**

Append to `Sources/agentNotch/CodexLimits.swift`:

```swift
// Scans <dir>/sessions/**/rollout-*.jsonl for the newest rate_limits snapshot.
// ponytail: 15s timer scan instead of FS watches — the rolling YYYY/MM/DD dir tree
// makes watch trees fiddly, and reads are byte-offset incremental so a scan is ~free.
// Upgrade to DispatchSource watches if the 15s latency ever matters.
final class CodexAccountProvider {
    private let dir: URL
    private let onUpdate: (AccountUsage) -> Void
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    private var partials: [String: Data] = [:]
    private var latest: CodexSnapshot?
    private var didInitialScan = false
    private var last: AccountUsage?

    init(dir: URL, onUpdate: @escaping (AccountUsage) -> Void) {
        self.dir = dir
        self.onUpdate = onUpdate
        self.queue = DispatchQueue(label: "agentNotch.codex.\(dir.lastPathComponent)", qos: .utility)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 15)
        t.setEventHandler { [weak self] in self?.scan() }
        timer = t
        t.resume()
    }

    private var label: String {
        let f = dir.appendingPathComponent("auth.json")
        if let d = FileManager.default.contents(atPath: f.path), let e = CodexLimits.email(fromAuthJSON: d) {
            return e
        }
        return dir.lastPathComponent
    }

    private func scan() {
        let sessions = dir.appendingPathComponent("sessions")
        var candidates: [(url: URL, mtime: Date)] = []
        if let en = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let f as URL in en where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                candidates.append((f, m))
            }
        }
        // Recent files always; plus (on first scan only) the single newest file even
        // if old — the last-known weekly number matters after days of no Codex use.
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        var toRead = candidates.filter { $0.mtime >= cutoff }
        if !didInitialScan, toRead.isEmpty, let newest = candidates.max(by: { $0.mtime < $1.mtime }) {
            toRead = [newest]
        }
        didInitialScan = true
        for c in toRead { ingest(path: c.url.path) }
        publish()
    }

    // Same incremental pattern as UsageEngine: only appended bytes, buffered partial lines.
    private func ingest(path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        var offset = offsets[path] ?? 0
        try? fh.seek(toOffset: offset)
        var buf = partials[path] ?? Data()
        while let chunk = try? fh.read(upToCount: 65_536), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                if let s = CodexLimits.snapshot(from: line),
                   latest == nil || s.asOf > latest!.asOf { latest = s }
            }
        }
        partials[path] = buf
        offsets[path] = offset
    }

    private func publish() {
        var acc = AccountUsage(id: "codex:\(dir.path)", product: .codex, label: label)
        if let snap = latest {
            // A window that has already reset since the snapshot reads as 0%.
            acc.windows = snap.windows.map { w in
                if let r = w.resetsAt, r < Date() {
                    return LimitWindow(name: w.name, percent: 0, resetsAt: nil)
                }
                return w
            }
            acc.asOf = snap.asOf
            acc.lastActivity = snap.asOf
        } else {
            acc.status = FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions").path)
                ? "no usage data yet" : "not found"
        }
        if acc != last { last = acc; onUpdate(acc) }
    }
}
```

- [x] **Step 2: Verify it builds and all tests still pass**

Run: `swift build && swift test`
Expected: clean build, all tests PASS.

- [x] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: Codex account provider scanning session rollouts"
```

---

### Task 6: LimitsEngine + wiring

**Files:**
- Create: `Sources/agentNotch/LimitsEngine.swift`
- Modify: `Sources/agentNotch/main.swift`
- Modify: `Sources/agentNotch/NotchPanel.swift` (dynamic expanded height)

**Interfaces:**
- Consumes: `AppConfig` (Task 1), both providers (Tasks 3, 5).
- Produces: `LimitsEngine(config: AppConfig, onPublish: @escaping ([AccountUsage]) -> Void)` with `func start()` — `onPublish` fires on the **main queue** with the full sorted account list. `NotchController.setAccountCount(_ n: Int)` recomputes geometry.

- [x] **Step 1: Implement LimitsEngine**

Create `Sources/agentNotch/LimitsEngine.swift`:

```swift
import Foundation

// Owns one provider per configured account dir; merges their updates into a
// single sorted list and hands it to the main thread.
final class LimitsEngine {
    private var claudeProviders: [ClaudeAccountProvider] = []
    private var codexProviders: [CodexAccountProvider] = []
    private var accounts: [String: AccountUsage] = [:]
    private let mergeQueue = DispatchQueue(label: "agentNotch.limits")
    private let onPublish: ([AccountUsage]) -> Void

    init(config: AppConfig, onPublish: @escaping ([AccountUsage]) -> Void) {
        self.onPublish = onPublish
        let update: (AccountUsage) -> Void = { [weak self] acc in
            self?.mergeQueue.async { self?.merge(acc) }
        }
        claudeProviders = config.claudeDirs.map { ClaudeAccountProvider(dir: $0, onUpdate: update) }
        codexProviders = config.codexDirs.map { CodexAccountProvider(dir: $0, onUpdate: update) }
    }

    func start() {
        claudeProviders.forEach { $0.start() }
        codexProviders.forEach { $0.start() }
    }

    private func merge(_ acc: AccountUsage) {
        accounts[acc.id] = acc
        let sorted = accounts.values.sorted {
            ($0.product.rawValue, $0.label, $0.id) < ($1.product.rawValue, $1.label, $1.id)
        }
        DispatchQueue.main.async { self.onPublish(sorted) }
    }
}
```

- [x] **Step 2: Dynamic expanded height in NotchPanel.swift**

In `NotchController`, add an account count field and setter, and use it in `computeRects()`. Replace the line

```swift
        let expanded = CGSize(width: max(540, collapsed.width + 140), height: 210)
```

with

```swift
        // Height grows with account rows: chrome (~120) + ~110 per account card.
        let height = max(210, CGFloat(120 + 110 * max(accountCount, 1)))
        let expanded = CGSize(width: max(540, collapsed.width + 140), height: height)
```

and add to the class (next to the other stored properties):

```swift
    private var accountCount = 1

    func setAccountCount(_ n: Int) {
        guard n != accountCount, n > 0 else { return }
        accountCount = n
        reposition()
    }
```

- [x] **Step 3: Wire it in main.swift**

Replace the body of `applicationDidFinishLaunching` in `Sources/agentNotch/main.swift`:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController!
    private var engine: UsageEngine!
    private var limits: LimitsEngine!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        engine = UsageEngine(store: controller.store)   // still feeds last-project footer
        engine.start()
        limits = LimitsEngine(config: AppConfig.load()) { [weak self] accounts in
            guard let self else { return }
            self.controller.store.accounts = accounts
            self.controller.setAccountCount(accounts.count)
        }
        limits.start()
        controller.show()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() { controller.reposition() }
}
```

- [x] **Step 4: Verify build and tests**

Run: `swift build && swift test`
Expected: clean build, all tests PASS.

- [x] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: LimitsEngine merges providers into the store; dynamic panel height"
```

---

### Task 7: UI — account rows and product gauges

**Files:**
- Modify: `Sources/agentNotch/NotchView.swift`
- Modify: `Sources/agentNotch/UsageEngine.swift` (delete the two cap constants)

**Interfaces:**
- Consumes: `UsageStore.accounts`, `AccountUsage`, `LimitWindow`, `Product`.
- Produces: UI only.

- [x] **Step 1: Add selection helpers**

Append to `Sources/agentNotch/Models.swift`:

```swift
extension AccountUsage {
    var maxPercent: Double? { windows.map(\.percent).max() }
    var activityStamp: Date { lastActivity ?? asOf ?? .distantPast }
}

extension UsageStore {
    // Collapsed pill shows the most-recently-active healthy account per product.
    func activeAccount(_ p: Product) -> AccountUsage? {
        accounts.filter { $0.product == p && $0.status == nil }
            .max { $0.activityStamp < $1.activityStamp }
    }
}
```

- [x] **Step 2: Rework NotchView.swift**

In `Sources/agentNotch/NotchView.swift`:

**(a)** Add a `CodexTile` next to `ClaudeTile` and a shared switcher:

```swift
// Rounded-square Codex mark, same tile language as ClaudeTile.
private struct CodexTile: View {
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(Color(white: 0.13))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            )
            .frame(width: size, height: size)
    }
}

@ViewBuilder private func productTile(_ p: Product, size: CGFloat) -> some View {
    switch p {
    case .claude: ClaudeTile(size: size)
    case .codex: CodexTile(size: size)
    }
}
```

**(b)** Replace `CollapsedContent` entirely:

```swift
// MARK: - Collapsed layout: per-product tile + ring in each wing

private struct CollapsedContent: View {
    var store: UsageStore
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            wing(.claude).frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth) // the physical notch sits here
            wing(.codex).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func wing(_ p: Product) -> some View {
        HStack(spacing: 8) {
            productTile(p, size: 24)
            if let a = store.activeAccount(p), let pct = a.maxPercent {
                RingGauge(fraction: min(max(pct / 100, 0), 1))
            } else {
                RingGauge(fraction: 0).opacity(0.3)
            }
        }
    }
}
```

**(c)** Replace `ExpandedContent` and `BarRow` entirely:

```swift
// MARK: - Expanded layout: one card per account

private struct ExpandedContent: View {
    var store: UsageStore

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 10) {
            Text("AGENT LIMITS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.45))
            if store.accounts.isEmpty {
                Text("waiting for account data…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            ForEach(store.accounts) { AccountRow(account: $0) }
            HStack {
                Text(s.lastProject ?? "no activity yet")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(peach.opacity(0.9))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let a = s.lastActivity {
                    Text(a, style: .relative)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40) // clear the physical notch / camera area
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AccountRow: View {
    let account: AccountUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                productTile(account.product, size: 26)
                Text(account.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let asOf = account.asOf, Date().timeIntervalSince(asOf) > 300 {
                    (Text("as of ") + Text(asOf, style: .relative) + Text(" ago"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            if let status = account.status {
                Text(status)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(dangerRed.opacity(0.9))
            } else {
                ForEach(account.windows, id: \.name) { w in
                    WindowBarRow(window: w)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.07))
        )
    }
}

private struct WindowBarRow: View {
    let window: LimitWindow

    var body: some View {
        let f = min(max(window.percent / 100, 0), 1)
        HStack(spacing: 10) {
            Text(window.name)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 36, alignment: .leading)
            Capsule().fill(.white.opacity(0.15))
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(usageColor(f))
                            .frame(width: max(g.size.width * f, f > 0 ? 6 : 0))
                    }
                }
                .frame(height: 6)
            Text("\(Int(window.percent.rounded()))%")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.white)
                .frame(width: 40, alignment: .trailing)
            if let r = window.resetsAt, r > .now {
                Text(timerInterval: Date.now...r, countsDown: true)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 62, alignment: .trailing)
            } else {
                Text("—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 62, alignment: .trailing)
            }
        }
    }
}
```

**(d)** Delete the now-unused `fraction(_:_:)` helper and the old `ResetTimer` struct from NotchView.swift (the collapsed reset column is gone; per-window timers replaced it). Keep `RingGauge`, `ClaudeTile`, `usageColor`, palette, shapes, blur.

**(e)** In `Sources/agentNotch/UsageEngine.swift`, delete the two cap constants and their comment block (`fiveHourCap` / `sevenDayCap` lines 3–6). Nothing else references them after (d).

- [x] **Step 3: Verify build and tests**

Run: `swift build && swift test`
Expected: clean build, all tests PASS.

- [ ] **Step 4: Manual acceptance run** (LEFT FOR HUMAN — executor cannot observe the GUI; `swift build -c release` verified to succeed)

Run: `swift run -c release` (needs a logged-in `~/.claude`; `~/.codex` optional).
Expected within ~60s of launch:
- Collapsed: Claude tile + ring showing the real max utilization %; Codex wing dimmed ring if no Codex data.
- Hover-expanded: one card per account — email label, one bar per window (5H/7D/OPUS for Claude; 5H/WEEK for Codex) with % and reset countdown; Codex card shows "as of N ago" when stale; accounts with problems show a status line instead of bars.
- Hover expand/collapse still buttery at 120Hz.

Kill with Ctrl-C.

- [x] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: per-account limit UI in collapsed and expanded notch"
```

---

### Task 8: Final verification

- [x] **Step 1: Full test suite + release build**

Run: `swift test && swift build -c release`
Expected: all tests PASS, clean release build.

- [x] **Step 2: Update ROADMAP.md**

Append under a new section at the end of `ROADMAP.md`:

```markdown
## Step 5 — Real limits, multi-account (done)

Real per-account limit data replaces cap estimation: Claude via the OAuth usage
endpoint (per config dir in `~/.agentnotch.json`, default `~/.claude`), Codex via
`rate_limits` snapshots in `~/.codex/sessions` rollouts. One card per account in
the expanded panel; collapsed wings show the most-recently-active account per
product. Spec: `docs/superpowers/specs/2026-07-07-real-limits-multi-account-design.md`.
```

- [x] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: roadmap update for real limits milestone"
```
