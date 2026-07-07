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
            return LimitWindow(name: k.name, percent: 100 - pct, resetsAt: resets)
        }
    }

    // <dir>/.claude.json — only the account email is interesting.
    static func email(fromClaudeJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = obj["oauthAccount"] as? [String: Any] else { return nil }
        return acct["emailAddress"] as? String
    }
}

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
