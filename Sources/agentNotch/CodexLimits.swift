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
