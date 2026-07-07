import Foundation
import Observation

// A single token-usage event pulled from a transcript line.
struct UsageEvent {
    let date: Date
    let tokens: Int
}

// The tiny, already-computed view model handed to the UI. Nothing else crosses threads.
struct UsageSnapshot: Equatable {
    var fiveHourTokens = 0
    var sevenDayTokens = 0
    var windowStart: Date? = nil
    var nextReset: Date? = nil
    var lastProject: String? = nil
    var lastActivity: Date? = nil
}

// One observable holder shared by the SwiftUI hierarchies. Unchanged subtrees don't re-render.
@Observable final class UsageStore {
    var snapshot = UsageSnapshot()
    var accounts: [AccountUsage] = []
}

// Minimal decodable matching Claude Code assistant transcript lines. Unknown fields ignored.
struct TranscriptLine: Decodable {
    let type: String?
    let timestamp: String?
    let message: Message?

    struct Message: Decodable { let usage: Usage? }
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
}

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
