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
    var startedAt: Date? = nil
    var lastActivity: Date
    var isActive = false        // mid-turn: the agent is working right now
    var isAlive = false         // the hosting terminal/CLI process is still open
    var cwd: String? = nil
    var transcriptPath: String
    var todos: [TodoItem] = []
    var activity: [ActivityEntry] = []
    var latestReply: String? = nil
    var repository: RepositorySummary? = nil
}

struct TodoItem: Equatable {
    var text: String
    var status: String   // lenient: "pending" / "in_progress" / "completed"
}

enum ActivityKind: Equatable {
    case shell, git, read, search, patch, write, toolOutput, reply, lifecycle, other
}

struct ActivityEntry: Equatable {
    let at: Date
    let kind: ActivityKind
    let label: String
    let target: String?
    let text: String

    init(at: Date, kind: ActivityKind, label: String, target: String? = nil, text: String? = nil) {
        self.at = at
        self.kind = kind
        self.label = label
        self.target = target
        self.text = text ?? (target.map { "\(label) · \($0)" } ?? label)
    }

    init(at: Date, text: String) {
        self.init(at: at, kind: .other, label: text, text: text)
    }
}

struct RepositorySummary: Equatable {
    let root: String
    let branch: String
    let changedFiles: Int
    let additions: Int
    let deletions: Int
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

// The widget can dock to any screen edge except the bottom edge. Position is
// normalized along the selected edge so it survives display-size changes.
enum WidgetEdge: String, Equatable, Codable {
    case top, left, right
}

// Pure geometry shared by the AppKit panel and its tests. The panel keeps one
// maximum-size transparent envelope so changing edge previews does not resize the
// window underneath the pointer.
enum WidgetGeometry {
    static let sideCollapsedSize = CGSize(width: 56, height: 220)
    static let topGripHitSize = CGSize(width: 48, height: 24)
    static let sideGripHitSize = CGSize(width: 24, height: 48)
    static let dragThreshold: CGFloat = 5
    static let dockPreviewDistance: CGFloat = 96
    static let dockHysteresis: CGFloat = 24
    static let gripProximityMargin: CGFloat = 28

    static func panelSize(maximumShapeSize: CGSize) -> CGSize {
        CGSize(width: maximumShapeSize.width + sideGripHitSize.width,
               height: maximumShapeSize.height + topGripHitSize.height)
    }

    static func panelRect(edge: WidgetEdge, position: Double, size: CGSize,
                          screenFrame frame: CGRect) -> CGRect {
        let normalized = CGFloat(clamp(position, lower: 0, upper: 1))
        switch edge {
        case .top:
            let centerX = clamp(frame.minX + frame.width * normalized,
                                lower: frame.minX + size.width / 2,
                                upper: frame.maxX - size.width / 2)
            return CGRect(x: centerX - size.width / 2, y: frame.maxY - size.height,
                          width: size.width, height: size.height)
        case .left:
            let centerY = clamp(frame.minY + frame.height * normalized,
                                lower: frame.minY + size.height / 2,
                                upper: frame.maxY - size.height / 2)
            return CGRect(x: frame.minX, y: centerY - size.height / 2,
                          width: size.width, height: size.height)
        case .right:
            let centerY = clamp(frame.minY + frame.height * normalized,
                                lower: frame.minY + size.height / 2,
                                upper: frame.maxY - size.height / 2)
            return CGRect(x: frame.maxX - size.width, y: centerY - size.height / 2,
                          width: size.width, height: size.height)
        }
    }

    // AppKit coordinates are bottom-up, so a top-docked shape occupies the top of
    // the transparent envelope while side shapes remain vertically centered.
    static func activeRect(edge: WidgetEdge, shapeSize: CGSize, bounds: CGRect) -> CGRect {
        switch edge {
        case .top:
            return CGRect(x: bounds.midX - shapeSize.width / 2,
                          y: bounds.maxY - shapeSize.height,
                          width: shapeSize.width, height: shapeSize.height)
        case .left:
            return CGRect(x: bounds.minX, y: bounds.midY - shapeSize.height / 2,
                          width: shapeSize.width, height: shapeSize.height)
        case .right:
            return CGRect(x: bounds.maxX - shapeSize.width,
                          y: bounds.midY - shapeSize.height / 2,
                          width: shapeSize.width, height: shapeSize.height)
        }
    }

    static func gripRect(edge: WidgetEdge, shapeRect: CGRect) -> CGRect {
        switch edge {
        case .top:
            return CGRect(x: shapeRect.midX - topGripHitSize.width / 2,
                          y: shapeRect.minY - topGripHitSize.height,
                          width: topGripHitSize.width, height: topGripHitSize.height)
        case .left:
            return CGRect(x: shapeRect.maxX,
                          y: shapeRect.midY - sideGripHitSize.height / 2,
                          width: sideGripHitSize.width, height: sideGripHitSize.height)
        case .right:
            return CGRect(x: shapeRect.minX - sideGripHitSize.width,
                          y: shapeRect.midY - sideGripHitSize.height / 2,
                          width: sideGripHitSize.width, height: sideGripHitSize.height)
        }
    }

    // The handle is hidden until the pointer is headed for it: this zone inflates
    // the grip hit rect so the handle fades in on approach — including from
    // outside the widget — before the pointer actually reaches the grip.
    static func gripProximityRect(edge: WidgetEdge, shapeRect: CGRect) -> CGRect {
        gripRect(edge: edge, shapeRect: shapeRect)
            .insetBy(dx: -gripProximityMargin, dy: -gripProximityMargin)
    }

    // SwiftUI's local coordinate system is top-down while AppKit's panel geometry
    // is bottom-up. Keep the interactive overlay aligned with the AppKit tracking
    // rectangle by flipping the shared result through the panel bounds.
    static func swiftUIGripRect(edge: WidgetEdge, shapeSize: CGSize, bounds: CGRect) -> CGRect {
        let appKitShape = activeRect(edge: edge, shapeSize: shapeSize, bounds: bounds)
        let appKitGrip = gripRect(edge: edge, shapeRect: appKitShape)
        return CGRect(x: appKitGrip.minX,
                      y: bounds.height - appKitGrip.maxY,
                      width: appKitGrip.width,
                      height: appKitGrip.height)
    }

    static func normalizedPosition(for point: CGPoint, edge: WidgetEdge,
                                   screenFrame frame: CGRect) -> Double {
        let value: CGFloat
        switch edge {
        case .top:
            value = frame.width > 0 ? (point.x - frame.minX) / frame.width : 0.5
        case .left, .right:
            value = frame.height > 0 ? (point.y - frame.minY) / frame.height : 0.5
        }
        return Double(clamp(value, lower: 0, upper: 1))
    }

    static func nearestEdge(to point: CGPoint, in frame: CGRect) -> WidgetEdge {
        edgeDistances(to: point, in: frame).min { $0.distance < $1.distance }?.edge ?? .top
    }

    static func dockingPreview(for point: CGPoint, in frame: CGRect,
                               currentEdge: WidgetEdge,
                               threshold: CGFloat = dockPreviewDistance,
                               hysteresis: CGFloat = dockHysteresis) -> WidgetEdge? {
        let distances = edgeDistances(to: point, in: frame)
        guard let best = distances.min(by: { $0.distance < $1.distance }),
              best.distance <= threshold else { return nil }

        guard best.edge != currentEdge,
              let current = distances.first(where: { $0.edge == currentEdge }) else {
            return best.edge
        }

        // Keep the current preview near a corner until the competing edge is
        // materially closer; this prevents rapid top/side flipping.
        if current.distance <= threshold + hysteresis,
           best.distance + hysteresis >= current.distance {
            return currentEdge
        }
        return best.edge
    }

    private static func edgeDistances(to point: CGPoint, in frame: CGRect)
        -> [(edge: WidgetEdge, distance: CGFloat)] {
        [
            (.top, abs(frame.maxY - point.y)),
            (.left, abs(point.x - frame.minX)),
            (.right, abs(frame.maxX - point.x)),
        ]
    }

    private static func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
        guard lower <= upper else { return lower }
        return min(max(value, lower), upper)
    }
}

struct WidgetPlacement: Equatable {
    private static let edgeKey = "widget.edge"
    private static let positionKey = "widget.position"

    var edge: WidgetEdge
    var position: Double

    init(edge: WidgetEdge = .top, position: Double = 0.5) {
        self.edge = edge
        self.position = min(max(position, 0), 1)
    }

    static func load(from defaults: UserDefaults = .standard) -> WidgetPlacement {
        let edge = (defaults.string(forKey: edgeKey)).flatMap(WidgetEdge.init(rawValue:)) ?? .top
        let position = (defaults.object(forKey: positionKey) as? NSNumber)?.doubleValue ?? 0.5
        return WidgetPlacement(edge: edge, position: position)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(edge.rawValue, forKey: Self.edgeKey)
        defaults.set(position, forKey: Self.positionKey)
    }
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
