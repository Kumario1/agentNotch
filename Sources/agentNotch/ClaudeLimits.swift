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
