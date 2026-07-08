import Foundation
import Observation

struct AgentSession: Equatable, Identifiable {
    let id: String
    let product: Product
    var sessionID: String? = nil
    var title: String
    var detail: String = "Working"
    var model: String? = nil
    var inputTokens = 0          // total in: fresh + cache-creation + cache-read
    var outputTokens = 0
    var cacheReadTokens = 0      // billed ~0.1x input
    var cacheCreationTokens = 0  // billed ~1.25x input (5-min write)
    var lastActivity: Date
    var isActive = false        // mid-turn: the agent is working right now
    var isAlive = false         // the hosting terminal/CLI process is still open
    var cwd: String? = nil
    var transcriptPath: String
    var todos: [TodoItem] = []
    var activity: [ActivityEntry] = []
}

struct TodoItem: Equatable {
    var text: String
    var status: String   // lenient: "pending" / "in_progress" / "completed"
}

struct ActivityEntry: Equatable {
    let at: Date
    let text: String
}

extension AgentSession {
    // Rough $ cost from token counts. Cache reads bill ~0.1x input and 5-min
    // cache writes ~1.25x (Anthropic prompt-caching pricing); charging all input
    // tokens at the full rate over-counts by ~10x on cache-heavy sessions.
    func estimatedCostUSD(inPer1M: Double, outPer1M: Double) -> Double {
        let fresh = max(0, inputTokens - cacheReadTokens - cacheCreationTokens)
        return Double(fresh) / 1_000_000 * inPer1M
            + Double(cacheCreationTokens) / 1_000_000 * inPer1M * 1.25
            + Double(cacheReadTokens) / 1_000_000 * inPer1M * 0.1
            + Double(outputTokens) / 1_000_000 * outPer1M
    }
}

enum ApprovalDecision: String, Equatable, Codable {
    case allow, deny, always
}

struct ApprovalRequest: Equatable, Identifiable {
    let id: String
    let product: Product
    let sessionTitle: String
    let toolName: String
    let summary: String
    let cwd: String?
    let receivedAt: Date
    let alwaysKey: String
}

// One observable holder shared by the SwiftUI hierarchies. Unchanged subtrees don't re-render.
@Observable final class UsageStore {
    var accounts: [AccountUsage] = []
    var sessions: [AgentSession] = []
    var pendingApprovals: [ApprovalRequest] = []
    var activeClaudeAccountID: String? = nil
    var pinnedSessionIDs: Set<String> = []
    var hiddenSessionIDs: Set<String> = []
    @ObservationIgnored var onPinsChanged: (() -> Void)? = nil   // engine handoff, wired in main.swift
}

// MARK: - Real-limit models (per-account, per-window)

enum Product: String, Equatable, Codable, CaseIterable {
    case claude, codex, cursor
}

struct LimitWindow: Equatable {
    let name: String        // "5H", "7D", "OPUS", "WEEK"
    let percent: Double     // 0–100 usage remaining
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

// MARK: - First-launch account discovery

enum AccountDiscovery {
    /// Claude account dirs: `~/.claude` plus any home child that looks like a Claude config
    /// (has `.credentials.json` or `.claude.json`).
    static func claudeDirs(home: URL, fm: FileManager = .default) -> [URL] {
        var found: [URL] = []
        let defaultDir = home.appendingPathComponent(".claude", isDirectory: true)
        if fm.fileExists(atPath: defaultDir.path) { found.append(defaultDir) }

        guard let kids = try? fm.contentsOfDirectory(
            at: home, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return found }

        for url in kids {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if url.path == defaultDir.path { continue }
            if isClaudeAccountDir(url, fm: fm) { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    static func codexDirs(home: URL, fm: FileManager = .default) -> [URL] {
        let dir = home.appendingPathComponent(".codex", isDirectory: true)
        return fm.fileExists(atPath: dir.path) ? [dir] : []
    }

    static func cursorDirs(home: URL, fm: FileManager = .default) -> [URL] {
        let dir = home.appendingPathComponent(".cursor", isDirectory: true)
        return fm.fileExists(atPath: dir.path) ? [dir] : []
    }

    private static func isClaudeAccountDir(_ url: URL, fm: FileManager) -> Bool {
        fm.fileExists(atPath: url.appendingPathComponent(".credentials.json").path)
            || fm.fileExists(atPath: url.appendingPathComponent(".claude.json").path)
    }
}

// MARK: - Config: which config dirs are accounts

struct AppConfig: Equatable {
    var claudeDirs: [URL]
    var codexDirs: [URL]
    var cursorDirs: [URL]
    var approvalsEnabledClaude: Bool
    var approvalsEnabledCursor: Bool
    var launchAtLogin: Bool

    static let configPath: String = NSString(string: "~/.agentnotch.json").expandingTildeInPath

    static func parse(_ data: Data?) -> AppConfig {
        var claude = ["~/.claude"], codex = ["~/.codex"], cursor = ["~/.cursor"]
        var approvalsClaude = false, approvalsCursor = false, launchAtLogin = false
        if let data,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            claude = obj["claude"] as? [String] ?? claude
            codex = obj["codex"] as? [String] ?? codex
            cursor = obj["cursor"] as? [String] ?? cursor
            approvalsClaude = obj["approvalsEnabledClaude"] as? Bool ?? approvalsClaude
            approvalsCursor = obj["approvalsEnabledCursor"] as? Bool ?? approvalsCursor
            launchAtLogin = obj["launchAtLogin"] as? Bool ?? launchAtLogin
        }
        func urls(_ paths: [String]) -> [URL] {
            paths.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
        }
        return AppConfig(
            claudeDirs: urls(claude),
            codexDirs: urls(codex),
            cursorDirs: urls(cursor),
            approvalsEnabledClaude: approvalsClaude,
            approvalsEnabledCursor: approvalsCursor,
            launchAtLogin: launchAtLogin)
    }

    /// Load config. When `~/.agentnotch.json` is missing, discover local account dirs,
    /// persist them, and return that config so first launch works with no setup.
    static func load(
        configPath: String = AppConfig.configPath,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> AppConfig {
        if let data = FileManager.default.contents(atPath: configPath) {
            return parse(data)
        }
        var discovered = parse(nil)
        let claude = AccountDiscovery.claudeDirs(home: home)
        let codex = AccountDiscovery.codexDirs(home: home)
        let cursor = AccountDiscovery.cursorDirs(home: home)
        if !claude.isEmpty { discovered.claudeDirs = claude }
        if !codex.isEmpty { discovered.codexDirs = codex }
        if !cursor.isEmpty { discovered.cursorDirs = cursor }
        discovered.save(to: configPath)
        return discovered
    }

    func save(to path: String = AppConfig.configPath) {
        let obj: [String: Any] = [
            "claude": claudeDirs.map(\.path),
            "codex": codexDirs.map(\.path),
            "cursor": cursorDirs.map(\.path),
            "approvalsEnabledClaude": approvalsEnabledClaude,
            "approvalsEnabledCursor": approvalsEnabledCursor,
            "launchAtLogin": launchAtLogin,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

extension AccountUsage {
    var activityStamp: Date { lastActivity ?? asOf ?? .distantPast }
}

extension UsageStore {
    // Collapsed pill shows the most-recently-active healthy account per product.
    func activeAccount(_ p: Product) -> AccountUsage? {
        accounts.filter { $0.product == p && $0.status == nil }
            .max { $0.activityStamp < $1.activityStamp }
    }

    // Two most-recently-active accounts across all products (for collapsed wings).
    func topActiveAccounts(limit: Int = 2) -> [AccountUsage] {
        Array(accounts.sorted { $0.activityStamp > $1.activityStamp }.prefix(limit))
    }

    var currentApproval: ApprovalRequest? { pendingApprovals.first }

    // MARK: - Organize (pin / dismiss) persistence — mirrors ApprovalServer's always-allow.json.

    private static let organizePath = NSString(string: "~/.agentnotch/organize.json").expandingTildeInPath

    func togglePin(_ id: String) {
        if pinnedSessionIDs.contains(id) { pinnedSessionIDs.remove(id) } else { pinnedSessionIDs.insert(id) }
        persistOrganize(); onPinsChanged?()
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        if hidden { hiddenSessionIDs.insert(id) } else { hiddenSessionIDs.remove(id) }
        persistOrganize()
    }

    func loadOrganize() {
        guard let data = FileManager.default.contents(atPath: Self.organizePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return }
        pinnedSessionIDs = Set(obj["pinned"] ?? [])
        hiddenSessionIDs = Set(obj["hidden"] ?? [])
    }

    func persistOrganize() {
        let obj = ["pinned": Array(pinnedSessionIDs).sorted(), "hidden": Array(hiddenSessionIDs).sorted()]
        let dir = (Self.organizePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.organizePath), options: .atomic)
    }
}
