import Foundation
import Observation

struct AgentSession: Equatable, Identifiable {
    let id: String
    let product: Product
    var sessionID: String? = nil
    var title: String
    var detail: String = "Working"
    var inputTokens = 0
    var outputTokens = 0
    var lastActivity: Date
    var isActive = false
    var cwd: String? = nil
    var transcriptPath: String
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

    static func load() -> AppConfig {
        parse(FileManager.default.contents(atPath: configPath))
    }

    func save() {
        let obj: [String: Any] = [
            "claude": claudeDirs.map(\.path),
            "codex": codexDirs.map(\.path),
            "cursor": cursorDirs.map(\.path),
            "approvalsEnabledClaude": approvalsEnabledClaude,
            "approvalsEnabledCursor": approvalsEnabledCursor,
            "launchAtLogin": launchAtLogin,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.configPath), options: .atomic)
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
}
