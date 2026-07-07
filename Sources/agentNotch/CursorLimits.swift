import Foundation

// Cursor has no quota file on disk, but the app authenticates its own backend with a
// JWT it caches in an Electron SQLite store. We read that token (read-only, never
// persisted or logged) and ask Cursor's dashboard service for the current-period usage.
//
// These endpoints are unofficial and may change; every parse is lenient and fails to a
// plain "connected" status rather than throwing.
enum CursorLimits {
    // Standard Electron state DB where Cursor caches `cursorAuth/accessToken`.
    static let stateDB = NSString(string:
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb").expandingTildeInPath

    static let usageURL = URL(string:
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

    // Reads the Bearer token via the sqlite3 CLI (read-only). Mirrors ClaudeAccountProvider
    // shelling out to `security` — Security/SQLite framework glue is more code for the same bytes.
    static func accessToken(stateDB path: String = stateDB) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path,
                       "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken' LIMIT 1;"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let token = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty == false) ? token : nil
    }

    // Map GetCurrentPeriodUsage `planUsage` into remaining-% windows that match the
    // Cursor dashboard meters. The current API reports usage as percentages of the
    // included budget — `apiPercentUsed` (named models, the "API" meter) and
    // `autoPercentUsed` (Auto) — which the dashboard shows as separate bars. We keep
    // both so the notch matches ("42% used" on the dashboard = ~58% remaining here).
    // `percent` is remaining (0–100), matching the Claude/Codex convention.
    //
    // Note: `totalSpend` can exceed `limit` thanks to free bonus usage, so the old
    // spend/limit math produced a bogus "0% left" — hence the percentage fields win.
    static func windows(fromPeriodUsage data: Data) -> [LimitWindow] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = obj["planUsage"] as? [String: Any] else { return [] }
        let resetsAt = epochMillis(obj["billingCycleEnd"])

        var windows: [LimitWindow] = []
        if let api = numeric(plan["apiPercentUsed"]), api.isFinite {
            windows.append(LimitWindow(name: "API", percent: clampPercent(100 - api), resetsAt: resetsAt))
        }
        if let auto = numeric(plan["autoPercentUsed"]), auto.isFinite {
            windows.append(LimitWindow(name: "AUTO", percent: clampPercent(100 - auto), resetsAt: resetsAt))
        }
        if !windows.isEmpty { return windows }

        // Fallbacks for plans that report a single figure instead of the split meters.
        if let used = numeric(plan["totalPercentUsed"]), used.isFinite {
            return [LimitWindow(name: "PLAN", percent: clampPercent(100 - used), resetsAt: resetsAt)]
        }
        if let limit = numeric(plan["limit"]), limit > 0 {
            let remaining = numeric(plan["remaining"]) ?? (limit - (numeric(plan["totalSpend"]) ?? 0))
            return [LimitWindow(name: "PLAN", percent: clampPercent(remaining / limit * 100), resetsAt: resetsAt)]
        }
        return []
    }

    private static func clampPercent(_ v: Double) -> Double { max(0, min(100, v)) }

    private static func epochMillis(_ v: Any?) -> Date? {
        guard let ms = numeric(v), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func numeric(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// Reports Cursor presence + last activity, and — when signed in — real current-period
// usage from the authenticated dashboard endpoint. Polls every 60s.
final class CursorAccountProvider {
    private let dir: URL
    private let onUpdate: (AccountUsage) -> Void
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var last: AccountUsage?
    // Keep the last good reading so a transient failure doesn't blank the notch.
    private var lastGoodWindows: [LimitWindow] = []
    private var lastGoodAsOf: Date?

    init(dir: URL, onUpdate: @escaping (AccountUsage) -> Void) {
        self.dir = dir
        self.onUpdate = onUpdate
        self.queue = DispatchQueue(label: "agentNotch.cursor.\(dir.lastPathComponent)", qos: .utility)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 60)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    // Newest transcript mtime = this account's last Cursor agent activity.
    private var lastActivity: Date? {
        let projects = dir.appendingPathComponent("projects", isDirectory: true)
        guard let en = FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: Date?
        for case let f as URL in en where f.pathExtension == "jsonl" {
            if let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               newest == nil || m > newest! { newest = m }
        }
        return newest
    }

    private func poll() {
        var acc = AccountUsage(id: "cursor:\(dir.path)", product: .cursor, label: "Cursor")
        acc.lastActivity = lastActivity

        let projects = dir.appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projects.path) else {
            acc.status = "not found"
            publish(acc)
            return
        }
        guard let token = CursorLimits.accessToken() else {
            acc.status = "sign in to Cursor"
            publish(acc)
            return
        }

        var req = URLRequest(url: CursorLimits.usageURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.httpBody = Data("{}".utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            self.queue.async {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 {
                    self.lastGoodWindows = []
                    acc.status = "re-login needed"
                } else if let data, code == 200 {
                    let windows = CursorLimits.windows(fromPeriodUsage: data)
                    if windows.isEmpty {
                        self.applyStaleOrStatus(&acc,
                            status: acc.lastActivity != nil ? "connected" : "no usage data")
                    } else {
                        self.lastGoodWindows = windows
                        self.lastGoodAsOf = Date()
                        acc.windows = windows
                        acc.asOf = self.lastGoodAsOf
                    }
                } else {
                    self.applyStaleOrStatus(&acc, status: "offline")
                }
                self.publish(acc)
            }
        }.resume()
    }

    // Prefer the last good numbers over a bare error, so a hiccup never blanks the UI.
    private func applyStaleOrStatus(_ acc: inout AccountUsage, status: String) {
        if !lastGoodWindows.isEmpty {
            acc.windows = lastGoodWindows
            acc.asOf = lastGoodAsOf
        } else {
            acc.status = status
        }
    }

    // Suppress no-op updates (asOf changes each successful poll; compare everything else).
    private func publish(_ acc: AccountUsage) {
        var a = acc, b = last
        a.asOf = nil; b?.asOf = nil
        if a != b { last = acc; onUpdate(acc) }
    }
}
