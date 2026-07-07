import Foundation

private let fiveHours: TimeInterval = 5 * 3600
private let sevenDays: TimeInterval = 7 * 24 * 3600

final class UsageEngine {
    private let store: UsageStore
    private let queue = DispatchQueue(label: "agentNotch.usage", qos: .utility)
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    private var events: [UsageEvent] = []           // time-sorted at publish time
    private var offsets: [String: UInt64] = [:]     // per-file byte offset already parsed
    private var partials: [String: Data] = [:]      // buffered partial trailing line per file
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var dirSources: [DispatchSourceFileSystemObject] = []
    private var lastProject: String?
    private var lastActivity: Date?
    private var publishScheduled = false

    init(store: UsageStore) { self.store = store }

    func start() {
        queue.async {
            self.initialScan()
            self.publishNow()
        }
    }

    // MARK: - Pure parsing / window math (unit-tested)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func event(from line: Data) -> UsageEvent? {
        guard let l = try? JSONDecoder().decode(TranscriptLine.self, from: line),
              l.type == "assistant",
              let ts = l.timestamp, let date = iso.date(from: ts),
              let u = l.message?.usage else { return nil }
        let tokens = (u.input_tokens ?? 0) + (u.output_tokens ?? 0)
            + (u.cache_creation_input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0)
        return UsageEvent(date: date, tokens: tokens)
    }

    // 5h window is anchored at the first event after the last reset; 7d is a plain rolling sum.
    static func compute(events raw: [UsageEvent], now: Date)
        -> (five: Int, seven: Int, windowStart: Date?, reset: Date?) {
        let events = raw.sorted { $0.date < $1.date }
        let sevenCut = now.addingTimeInterval(-sevenDays)
        let seven = events.filter { $0.date >= sevenCut }.reduce(0) { $0 + $1.tokens }

        var start: Date?
        for e in events {
            if let s = start { if e.date >= s + fiveHours { start = e.date } }
            else { start = e.date }
        }
        guard let s = start, now < s + fiveHours else { return (0, seven, nil, nil) }
        let five = events.filter { $0.date >= s }.reduce(0) { $0 + $1.tokens }
        return (five, seven, s, s + fiveHours)
    }

    // MARK: - Ingestion

    private func initialScan() {
        watchDir(root)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().addingTimeInterval(-sevenDays)
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            watchDir(dir)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mtime, mtime < cutoff { continue } // can't contribute to any window
                ingest(path: f.path)
                watchFile(path: f.path)
            }
        }
    }

    // Read only appended bytes (from the stored offset to EOF), in chunks — never the whole file.
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
                if let e = Self.event(from: line) {
                    events.append(e)
                    if lastActivity == nil || e.date > lastActivity! {
                        lastActivity = e.date
                        lastProject = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                    }
                }
            }
        }
        partials[path] = buf
        offsets[path] = offset
        requestPublish()
    }

    // MARK: - Live file-system watching

    private func watchDir(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: queue)
        src.setEventHandler { [weak self] in self?.scanDir(url) }
        src.setCancelHandler { close(fd) }
        dirSources.append(src)
        src.resume()
    }

    private func scanDir(_ url: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "jsonl" && fileSources[f.path] == nil {
            ingest(path: f.path)
            watchFile(path: f.path)
        }
    }

    private func watchFile(path: String) {
        guard fileSources[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        src.setEventHandler { [weak self] in self?.ingest(path: path) }
        src.setCancelHandler { close(fd) }
        fileSources[path] = src
        src.resume()
    }

    // MARK: - Debounced publish (<= 4/sec)

    private func requestPublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.publishScheduled = false
            self?.publishNow()
        }
    }

    private func publishNow() {
        let now = Date()
        events.removeAll { $0.date < now.addingTimeInterval(-sevenDays) } // prune, bounds memory
        let (five, seven, windowStart, reset) = Self.compute(events: events, now: now)
        let snap = UsageSnapshot(
            fiveHourTokens: five, sevenDayTokens: seven,
            windowStart: windowStart, nextReset: reset,
            lastProject: lastProject, lastActivity: lastActivity)
        DispatchQueue.main.async { [store] in store.snapshot = snap }
    }
}
