import Foundation

// ponytail: "current" narrows files to parse; transcript terminal events decide live rows.
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

        let before = s.detail
        switch product {
        case .claude:
            applyClaude(obj, message: message, to: &s)
        case .codex:
            applyCodex(payload, to: &s)
        case .cursor:
            applyCursor(obj, message: message, to: &s)
        }
        if s.detail != before { appendActivity(&s, s.detail) }
    }

    private static func applyClaude(_ obj: [String: Any], message: [String: Any]?, to s: inout AgentSession) {
        if let usage = message?["usage"] as? [String: Any] {
            s.inputTokens += int(usage["input_tokens"])
                + int(usage["cache_creation_input_tokens"])
                + int(usage["cache_read_input_tokens"])
            s.outputTokens += int(usage["output_tokens"])
        }
        if let m = message?["model"] as? String, !m.isEmpty { s.model = m }

        guard let type = obj["type"] as? String else { return }
        if isClaudeStop(obj) {
            s.isActive = false
            s.detail = "Idle"   // turn done; the row persists (dimmed) while the terminal stays open
            return
        }
        // `last-prompt` records the just-submitted prompt at the START of a turn (no
        // timestamp), then the model may think for a minute before its first line.
        // It's a turn-start marker, not a stop — treating it as inactive hid the
        // session during that gap ("No sessions" mid-run).
        if type == "last-prompt" {
            s.isActive = true
            if let p = clean(obj["lastPrompt"] as? String) { s.detail = p }
            return
        }
        if type == "user" { s.isActive = true }
        if type == "queue-operation", let op = obj["operation"] as? String {
            s.isActive = true
            s.detail = op == "enqueue" ? "Queued" : op.capitalized
            return
        }
        guard let message else {
            if let text = clean(obj["content"] as? String) { s.detail = text }
            return
        }
        let role = message["role"] as? String ?? type
        if role == "assistant" {
            s.isActive = true
            if let tool = toolName(message["content"]) {
                let input = firstToolInput(message["content"])
                s.detail = toolDetail(tool, input)
                if tool == "TodoWrite", let t = parseTodos(input) { s.todos = t }
            } else if text(message["content"]) != nil {
                s.detail = "Replying"
            }
            if message["stop_reason"] as? String == "end_turn" {
                s.isActive = false
                s.detail = "Idle"
            }
        } else if let t = text(message["content"]) {
            s.isActive = true
            s.detail = t
        }
    }

    private static func applyCodex(_ payload: [String: Any]?, to s: inout AgentSession) {
        guard let payload else { return }
        if let usage = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] {
            s.inputTokens = int(usage["input_tokens"])
            s.outputTokens = int(usage["output_tokens"])
        }
        if let m = payload["model"] as? String, !m.isEmpty { s.model = m }
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "function_call", "custom_tool_call":
            s.isActive = true
            s.detail = "Running \((payload["name"] as? String) ?? "tool")"
        case "function_call_output", "custom_tool_call_output":
            s.isActive = true
            s.detail = "Reading output"
        case "agent_message":
            s.isActive = true
            s.detail = "Replying"
        case "reasoning":
            s.isActive = true
            s.detail = "Thinking"
        case "task_started":
            s.isActive = true
            s.detail = "Working"
        case "task_complete":
            s.isActive = false
            s.detail = "Done"
        case "turn_aborted":
            s.isActive = false
            s.detail = "Stopped"
        case "patch_apply_end":
            s.isActive = true
            s.detail = "Applying patch"
        case "message", "user_message":
            s.isActive = true
            if let t = text(payload["content"]) ?? clean(payload["message"] as? String) { s.detail = t }
        default:
            break
        }
    }

    private static func applyCursor(_ obj: [String: Any], message: [String: Any]?, to s: inout AgentSession) {
        // Cursor writes a `turn_ended` line when the agent finishes a turn. Without
        // this the session would look "active" forever and never leave the list.
        if obj["type"] as? String == "turn_ended" {
            s.isActive = false
            s.detail = "Done"
            return
        }
        let role = obj["role"] as? String ?? message?["role"] as? String
        guard let role else { return }

        // Cursor transcripts carry no `cwd`; recover it (and a real title) by matching an
        // absolute path from a tool call against the project-dir slug in the transcript path.
        if s.cwd == nil,
           let slug = cursorSlug(fromPath: s.transcriptPath),
           let input = firstToolInput(message?["content"]),
           let cwd = cursorCwd(forToolInput: input, slug: slug) {
            s.cwd = cwd
            s.title = title(from: cwd, fallbackPath: s.transcriptPath)
        }

        if role == "assistant" {
            s.isActive = true
            if let tool = toolName(message?["content"]) {
                s.detail = "Running \(tool)"
            } else if let t = text(message?["content"]) {
                s.detail = String(t.prefix(80))
            } else {
                s.detail = "Replying"
            }
        } else if role == "user" {
            s.isActive = true
            if let t = text(message?["content"]) {
                s.detail = String(t.prefix(80))
            }
        } else if role == "tool" {
            s.isActive = true
            s.detail = "Tool output"
        }

        if let usage = message?["usage"] as? [String: Any] {
            s.inputTokens += int(usage["input_tokens"] ?? usage["prompt_tokens"])
            s.outputTokens += int(usage["output_tokens"] ?? usage["completion_tokens"])
        }
    }

    private static func isClaudeStop(_ obj: [String: Any]) -> Bool {
        if let subtype = obj["subtype"] as? String,
           subtype == "stop_hook_summary" || subtype == "turn_duration" {
            return true
        }
        let hook = (obj["attachment"] as? [String: Any])?["hookName"] as? String
        return hook == "Stop"
    }

    private static func title(from cwd: String?, fallbackPath: String) -> String {
        if let cwd, !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty { return name }
        }
        // Cursor paths: .../projects/Users-foo-bar/agent-transcripts/uuid/uuid.jsonl
        // The slug is an absolute path with "/" replaced by "-"; we can't perfectly
        // reverse it (project names may contain "-"), so show the trailing segment after
        // the last known container ("Documents", "Desktop", ...) rather than a lone word.
        if let slug = cursorSlug(fromPath: fallbackPath) {
            let name = projectName(fromSlug: slug)
            if !name.isEmpty { return name }
        }
        let parent = URL(fileURLWithPath: fallbackPath).deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "Session" : parent
    }

    // Cursor project-dir slug lives right after "projects" in the transcript path.
    static func cursorSlug(fromPath path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let idx = parts.firstIndex(of: "projects"), idx + 1 < parts.count else { return nil }
        return String(parts[idx + 1])
    }

    // Best-effort readable name from a slug when no real cwd is known yet.
    private static func projectName(fromSlug slug: String) -> String {
        let containers: Set<String> = ["Documents", "Desktop", "Downloads", "Developer", "code", "src", "projects", "work", "repos", "git", "worktrees"]
        let comps = slug.split(separator: "-").map(String.init)
        if let last = comps.lastIndex(where: { containers.contains($0) }), last + 1 < comps.count {
            return comps[(last + 1)...].joined(separator: "-")
        }
        return comps.last ?? slug
    }

    // Resolve the working directory by matching a tool call's absolute path (or an
    // ancestor of it) against the project slug — slugify(dir) == slug pins the exact cwd.
    static func cursorCwd(forToolInput input: [String: Any], slug: String) -> String? {
        let candidates = ["path", "target_directory", "targetDirectory", "file", "filePath", "cwd"]
            .compactMap { input[$0] as? String }
            .filter { $0.hasPrefix("/") }
        for abs in candidates {
            var dir = URL(fileURLWithPath: abs)
            for _ in 0..<20 {
                if slugify(dir.path) == slug { return dir.path }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    private static func slugify(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/") { p.removeFirst() }
        if p.hasSuffix("/") { p.removeLast() }
        return p.replacingOccurrences(of: "/", with: "-")
    }

    private static func firstToolInput(_ content: Any?) -> [String: Any]? {
        guard let parts = content as? [[String: Any]] else { return nil }
        for p in parts {
            let type = p["type"] as? String
            if type == "tool_use" || type == "tool_call" {
                return p["input"] as? [String: Any] ?? p["args"] as? [String: Any]
            }
        }
        return nil
    }

    private static func toolName(_ content: Any?) -> String? {
        guard let parts = content as? [[String: Any]] else { return nil }
        for p in parts {
            let type = p["type"] as? String
            if type == "tool_use" || type == "tool_call" {
                return p["name"] as? String ?? p["toolName"] as? String
            }
        }
        return nil
    }

    // Rich detail for a Claude tool call: "Running Bash · git status", "Running Read · Models.swift".
    // Falls back to "Running <tool>" when there's no useful target — keeps existing rows/tests intact.
    private static func toolDetail(_ name: String, _ input: [String: Any]?) -> String {
        guard let target = toolTarget(input) else { return "Running \(name)" }
        return "Running \(name) · \(target)"
    }

    private static func toolTarget(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if let cmd = clean(input["command"] as? String) { return snippet(cmd) }
        for k in ["file_path", "path", "notebook_path", "filePath"] {
            if let p = input[k] as? String, !p.isEmpty { return URL(fileURLWithPath: p).lastPathComponent }
        }
        if let q = clean(input["query"] as? String) ?? clean(input["pattern"] as? String) { return snippet(q) }
        if let u = input["url"] as? String, !u.isEmpty { return snippet(u) }
        return nil
    }

    private static func snippet(_ s: String) -> String {
        s.count > 44 ? String(s.prefix(44)) + "…" : s
    }

    // Latest TodoWrite call = current checklist (Claude re-emits the whole list each call).
    private static func parseTodos(_ input: [String: Any]?) -> [TodoItem]? {
        guard let arr = input?["todos"] as? [[String: Any]] else { return nil }
        let items = arr.compactMap { d -> TodoItem? in
            guard let c = (d["content"] as? String) ?? (d["activeForm"] as? String) else { return nil }
            return TodoItem(text: c, status: (d["status"] as? String) ?? "pending")
        }
        return items.isEmpty ? nil : items
    }

    // Ring buffer (~8) of activity transitions — feeds the detail-card timeline.
    private static func appendActivity(_ s: inout AgentSession, _ text: String) {
        guard !text.isEmpty, text != s.activity.last?.text else { return }
        s.activity.append(ActivityEntry(at: s.lastActivity, text: text))
        if s.activity.count > 8 { s.activity.removeFirst() }
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
        // Strip harness meta tags (keeping their inner text) and ANSI color codes
        // so raw "<local-command-stdout>…" never shows in the notch.
        let oneLine = s
            .replacingOccurrences(
                of: "</?(?:local-command-stdout|local-command-caveat|command-name|command-message|command-args|system-reminder)>",
                with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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
    private var pinnedSnapshot: Set<String> = []   // pins mirrored here so scan (utility queue) reads them race-free

    init(config: AppConfig, store: UsageStore) {
        self.config = config
        self.store = store
    }

    // Called from the main thread when the user pins/unpins; hop onto our queue.
    func updatePinned(_ ids: Set<String>) {
        queue.async { self.pinnedSnapshot = ids }
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

        // Ingest every current transcript, active or not: keeping inactive sessions'
        // parsed state (cumulative tokens, recovered cwd/title, sessionID) means a
        // session that goes quiet and resumes continues its counts instead of
        // rebuilding from an empty struct at the current byte offset.
        for dir in config.claudeDirs {
            let root = dir.appendingPathComponent("projects", isDirectory: true)
            let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for p in projects {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: p, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for f in files where f.pathExtension == "jsonl" {
                    if isCurrent(f, cutoff: cutoff) { _ = ingest(f, product: .claude) }
                }
            }
        }

        for dir in config.codexDirs {
            let root = dir.appendingPathComponent("sessions", isDirectory: true)
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let f as URL in en where f.pathExtension == "jsonl" {
                if isCurrent(f, cutoff: cutoff) { _ = ingest(f, product: .codex) }
            }
        }

        for dir in config.cursorDirs {
            let root = dir.appendingPathComponent("projects", isDirectory: true)
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let f as URL in en where f.path.contains("agent-transcripts") && f.pathExtension == "jsonl" {
                if isCurrent(f, cutoff: cutoff) { _ = ingest(f, product: .cursor) }
            }
        }

        // A session stays listed until its terminal actually closes, not just while
        // it's mid-turn. Probe process liveness only when something is idle and could
        // be kept alive — no ps/lsof when everything's already active or there's nothing.
        let needLiveness = sessions.values.contains { !$0.isActive && $0.cwd != nil }
        let live = needLiveness ? SessionLiveness.liveKeys() : []
        for path in Array(sessions.keys) {
            guard var s = sessions[path] else { continue }
            s.isAlive = s.cwd.map { live.contains(SessionLiveness.key(product: s.product, cwd: $0)) } ?? false
            // Prune only when idle-dead AND aged out: an open-but-idle terminal is never
            // dropped, while abandoned tail state can't grow without bound.
            if s.lastActivity < cutoff && !s.isAlive && !pinnedSnapshot.contains(path) {
                sessions[path] = nil
                offsets[path] = nil
                partials[path] = nil
            } else {
                sessions[path] = s
            }
        }

        let sorted = SessionEngine.publishable(sessions.values, pinned: pinnedSnapshot)
        DispatchQueue.main.async { [store] in
            if store.sessions != sorted { store.sessions = sorted }
        }
    }

    // Shown rows: working (mid-turn) or terminal-alive, working ones first, newest
    // first within each group. Pure so it's unit-testable without touching disk.
    static func publishable<S: Sequence>(_ sessions: S, pinned: Set<String> = []) -> [AgentSession] where S.Element == AgentSession {
        sessions
            .filter { $0.isActive || $0.isAlive || pinned.contains($0.id) }
            .sorted { lhs, rhs in
                let lp = pinned.contains(lhs.id), rp = pinned.contains(rhs.id)
                if lp != rp { return lp }                              // pinned first
                if lhs.isActive != rhs.isActive { return lhs.isActive } // then working
                return lhs.lastActivity > rhs.lastActivity             // then newest
            }
    }

    private func isCurrent(_ url: URL, cutoff: Date) -> Bool {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (m ?? .distantPast) >= cutoff
    }

    private func ingest(_ url: URL, product: Product) -> AgentSession? {
        let path = url.path
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
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
        return session
    }
}
