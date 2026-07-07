import Foundation

// ponytail: "current" is recent mtime; replace with PID/socket liveness when hooks exist.
private let currentSessionAge: TimeInterval = 4 * 3600

enum SessionParsing {
    static func empty(path: String, product: Product, modifiedAt: Date) -> AgentSession {
        AgentSession(
            id: path, product: product,
            title: title(from: nil, fallbackPath: path),
            detail: "Starting",
            lastActivity: modifiedAt,
            transcriptPath: path)
    }

    static func apply(_ line: Data, product: Product, to s: inout AgentSession) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let payload = obj["payload"] as? [String: Any]
        let message = obj["message"] as? [String: Any]

        if let ts = (obj["timestamp"] as? String).flatMap(parseISO8601) {
            s.lastActivity = max(s.lastActivity, ts)
        }
        if let cwd = obj["cwd"] as? String ?? payload?["cwd"] as? String, !cwd.isEmpty {
            s.cwd = cwd
            s.title = title(from: cwd, fallbackPath: s.transcriptPath)
        }
        if let sid = obj["sessionId"] as? String ?? payload?["id"] as? String ?? payload?["turn_id"] as? String {
            s.sessionID = sid
        }

        if product == .claude {
            applyClaude(obj, message: message, to: &s)
        } else {
            applyCodex(payload, to: &s)
        }
    }

    private static func applyClaude(_ obj: [String: Any], message: [String: Any]?, to s: inout AgentSession) {
        if let usage = message?["usage"] as? [String: Any] {
            s.inputTokens += int(usage["input_tokens"])
                + int(usage["cache_creation_input_tokens"])
                + int(usage["cache_read_input_tokens"])
            s.outputTokens += int(usage["output_tokens"])
        }

        guard let type = obj["type"] as? String else { return }
        if type == "queue-operation", let op = obj["operation"] as? String {
            s.detail = op == "enqueue" ? "Queued" : op.capitalized
            return
        }
        guard let message else {
            if let text = clean(obj["content"] as? String) { s.detail = text }
            return
        }
        let role = message["role"] as? String ?? type
        if role == "assistant" {
            if let tool = toolName(message["content"]) {
                s.detail = "Running \(tool)"
            } else if text(message["content"]) != nil {
                s.detail = "Replying"
            }
        } else if let t = text(message["content"]) {
            s.detail = t
        }
    }

    private static func applyCodex(_ payload: [String: Any]?, to s: inout AgentSession) {
        guard let payload else { return }
        if let usage = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] {
            s.inputTokens = int(usage["input_tokens"])
            s.outputTokens = int(usage["output_tokens"])
        }
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "function_call", "custom_tool_call":
            s.detail = "Running \((payload["name"] as? String) ?? "tool")"
        case "function_call_output", "custom_tool_call_output":
            s.detail = "Reading output"
        case "agent_message":
            s.detail = "Replying"
        case "reasoning":
            s.detail = "Thinking"
        case "task_started":
            s.detail = "Working"
        case "task_complete":
            s.detail = "Done"
        case "turn_aborted":
            s.detail = "Stopped"
        case "patch_apply_end":
            s.detail = "Applying patch"
        case "message", "user_message":
            if let t = text(payload["content"]) ?? clean(payload["message"] as? String) { s.detail = t }
        default:
            break
        }
    }

    private static func title(from cwd: String?, fallbackPath: String) -> String {
        if let cwd, !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty { return name }
        }
        let parent = URL(fileURLWithPath: fallbackPath).deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "Session" : parent
    }

    private static func toolName(_ content: Any?) -> String? {
        guard let parts = content as? [[String: Any]] else { return nil }
        return parts.first { $0["type"] as? String == "tool_use" }?["name"] as? String
    }

    private static func text(_ content: Any?) -> String? {
        if let s = clean(content as? String) { return s }
        guard let parts = content as? [[String: Any]] else { return nil }
        for p in parts {
            if let s = clean(p["text"] as? String ?? p["content"] as? String) { return s }
        }
        return nil
    }

    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.isEmpty ? nil : oneLine
    }

    private static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return 0
    }
}

final class SessionEngine {
    private let config: AppConfig
    private let store: UsageStore
    private let queue = DispatchQueue(label: "agentNotch.sessions", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    private var partials: [String: Data] = [:]
    private var sessions: [String: AgentSession] = [:]

    init(config: AppConfig, store: UsageStore) {
        self.config = config
        self.store = store
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in self?.scan() }
        timer = t
        t.resume()
    }

    private func scan() {
        let cutoff = Date().addingTimeInterval(-currentSessionAge)
        var live = Set<String>()

        for dir in config.claudeDirs {
            let root = dir.appendingPathComponent("projects", isDirectory: true)
            let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for p in projects {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: p, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for f in files where f.pathExtension == "jsonl" {
                    if isCurrent(f, cutoff: cutoff) { live.insert(f.path); ingest(f, product: .claude) }
                }
            }
        }

        for dir in config.codexDirs {
            let root = dir.appendingPathComponent("sessions", isDirectory: true)
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let f as URL in en where f.pathExtension == "jsonl" {
                if isCurrent(f, cutoff: cutoff) { live.insert(f.path); ingest(f, product: .codex) }
            }
        }

        sessions = sessions.filter { live.contains($0.key) && $0.value.lastActivity >= cutoff }
        let sorted = sessions.values.sorted { $0.lastActivity > $1.lastActivity }
        DispatchQueue.main.async { [store] in
            if store.sessions != sorted { store.sessions = sorted }
        }
    }

    private func isCurrent(_ url: URL, cutoff: Date) -> Bool {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (m ?? .distantPast) >= cutoff
    }

    private func ingest(_ url: URL, product: Product) {
        let path = url.path
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        var session = sessions[path] ?? SessionParsing.empty(path: path, product: product, modifiedAt: modified)
        var offset = offsets[path] ?? 0
        try? fh.seek(toOffset: offset)
        var buf = partials[path] ?? Data()
        while let chunk = try? fh.read(upToCount: 65_536), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                SessionParsing.apply(line, product: product, to: &session)
            }
        }
        session.lastActivity = max(session.lastActivity, modified)
        partials[path] = buf
        offsets[path] = offset
        sessions[path] = session
    }
}
