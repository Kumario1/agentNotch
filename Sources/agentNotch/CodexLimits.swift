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
