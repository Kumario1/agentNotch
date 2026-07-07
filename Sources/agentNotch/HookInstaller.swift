import Foundation

enum HookInstaller {
    static let hookName = "agentnotch-approval"
    static let claudeSettings = NSString(string: "~/.claude/settings.json").expandingTildeInPath
    static let cursorHooks = NSString(string: "~/.cursor/hooks.json").expandingTildeInPath

    static func hookPath() -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent().appendingPathComponent("agentnotch-hook").path
    }

    static func claudeInstalled(settingsPath: String = claudeSettings) -> Bool {
        guard let hooks = loadJSON(settingsPath)?["hooks"] as? [String: Any],
              let entries = hooks["PreToolUse"] as? [[String: Any]] else { return false }
        return entries.contains { isOurs($0) }
    }

    static func cursorInstalled() -> Bool {
        guard let hooks = loadJSON(cursorHooks)?["hooks"] as? [String: Any] else { return false }
        let shell = hooks["beforeShellExecution"] as? [[String: Any]] ?? []
        return shell.contains { isOurs($0) }
    }

    @discardableResult
    static func installClaude(settingsPath: String = claudeSettings) -> Bool {
        var root = loadJSON(settingsPath) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var entries = hooks["PreToolUse"] as? [[String: Any]] ?? []
        entries.removeAll { isOurs($0) }
        entries.insert(ourEntry(), at: 0)
        hooks["PreToolUse"] = entries
        root["hooks"] = hooks
        return writeJSON(root, to: settingsPath)
    }

    @discardableResult
    static func uninstallClaude(settingsPath: String = claudeSettings) -> Bool {
        guard var root = loadJSON(settingsPath),
              var hooks = root["hooks"] as? [String: Any],
              var entries = hooks["PreToolUse"] as? [[String: Any]] else { return true }
        entries.removeAll { isOurs($0) }
        hooks["PreToolUse"] = entries
        root["hooks"] = hooks
        return writeJSON(root, to: settingsPath)
    }

    @discardableResult
    static func installCursor() -> Bool {
        var root = loadJSON(cursorHooks) ?? ["version": 1]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Only gate real shell commands. `preToolUse` fires for every tool (even
        // read-only ones) and can't present an interactive "ask", so intercepting
        // it just floods the notch — and its payload carries `tool_name`, which used
        // to make Cursor prompts show up mislabeled as Claude.
        var shell = hooks["beforeShellExecution"] as? [[String: Any]] ?? []
        shell.removeAll { isOurs($0) }
        shell.insert(ourCursorEntry(), at: 0)
        hooks["beforeShellExecution"] = shell
        // Remove any preToolUse entry a previous version of us installed.
        if var pre = hooks["preToolUse"] as? [[String: Any]] {
            pre.removeAll { isOurs($0) }
            if pre.isEmpty { hooks.removeValue(forKey: "preToolUse") } else { hooks["preToolUse"] = pre }
        }
        root["hooks"] = hooks
        if root["version"] == nil { root["version"] = 1 }
        return writeJSON(root, to: cursorHooks)
    }

    @discardableResult
    static func uninstallCursor() -> Bool {
        guard var root = loadJSON(cursorHooks),
              var hooks = root["hooks"] as? [String: Any] else { return true }
        for key in ["beforeShellExecution", "preToolUse"] {
            guard var entries = hooks[key] as? [[String: Any]] else { continue }
            entries.removeAll { isOurs($0) }
            hooks[key] = entries
        }
        root["hooks"] = hooks
        return writeJSON(root, to: cursorHooks)
    }

    static func sync(config: AppConfig) {
        if config.approvalsEnabledClaude { installClaude() } else { uninstallClaude() }
        if config.approvalsEnabledCursor { installCursor() } else { uninstallCursor() }
    }

    // MARK: - Helpers

    // Claude Code's `PreToolUse` uses a three-level shape: a matcher group with a
    // nested `hooks` array of handlers. A flat `{command,type}` entry (the shape we
    // used to write, and the shape Cursor wants) is silently ignored by Claude, so
    // the hook never fires and nothing ever reaches the notch. `matcher: "*"` fires
    // for every tool; the hook itself auto-allows the safe ones.
    private static func ourEntry() -> [String: Any] {
        [
            "matcher": "*",
            "hooks": [
                ["type": "command", "command": hookPath(), "timeout": 120, "hookName": hookName],
            ],
        ]
    }

    private static func ourCursorEntry() -> [String: Any] {
        ["command": hookPath(), "timeout": 120, "hookName": hookName]
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        if matchesUs(entry) { return true }
        // Claude nests handlers under `hooks`; look inside so we can detect (and, on
        // reinstall, clean up) both the legacy flat entry and the current nested one.
        if let nested = entry["hooks"] as? [[String: Any]] {
            return nested.contains(where: matchesUs)
        }
        return false
    }

    private static func matchesUs(_ entry: [String: Any]) -> Bool {
        if entry["hookName"] as? String == hookName { return true }
        return (entry["command"] as? String ?? "").hasSuffix("agentnotch-hook")
    }

    private static func loadJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    @discardableResult
    private static func writeJSON(_ obj: [String: Any], to path: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
