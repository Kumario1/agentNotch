import Foundation

enum HookInstaller {
    static let hookName = "agentnotch-approval"
    static let claudeSettings = NSString(string: "~/.claude/settings.json").expandingTildeInPath
    static let cursorHooks = NSString(string: "~/.cursor/hooks.json").expandingTildeInPath

    static func hookPath() -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent().appendingPathComponent("agentnotch-hook").path
    }

    static func claudeInstalled() -> Bool {
        guard let hooks = loadJSON(claudeSettings)?["hooks"] as? [String: Any],
              let entries = hooks["PreToolUse"] as? [[String: Any]] else { return false }
        return entries.contains { isOurs($0) }
    }

    static func cursorInstalled() -> Bool {
        guard let hooks = loadJSON(cursorHooks)?["hooks"] as? [String: Any] else { return false }
        let shell = hooks["beforeShellExecution"] as? [[String: Any]] ?? []
        let tool = hooks["preToolUse"] as? [[String: Any]] ?? []
        return shell.contains { isOurs($0) } || tool.contains { isOurs($0) }
    }

    @discardableResult
    static func installClaude() -> Bool {
        var root = loadJSON(claudeSettings) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var entries = hooks["PreToolUse"] as? [[String: Any]] ?? []
        entries.removeAll { isOurs($0) }
        entries.insert(ourEntry(), at: 0)
        hooks["PreToolUse"] = entries
        root["hooks"] = hooks
        return writeJSON(root, to: claudeSettings)
    }

    @discardableResult
    static func uninstallClaude() -> Bool {
        guard var root = loadJSON(claudeSettings),
              var hooks = root["hooks"] as? [String: Any],
              var entries = hooks["PreToolUse"] as? [[String: Any]] else { return true }
        entries.removeAll { isOurs($0) }
        hooks["PreToolUse"] = entries
        root["hooks"] = hooks
        return writeJSON(root, to: claudeSettings)
    }

    @discardableResult
    static func installCursor() -> Bool {
        var root = loadJSON(cursorHooks) ?? ["version": 1]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for key in ["beforeShellExecution", "preToolUse"] {
            var entries = hooks[key] as? [[String: Any]] ?? []
            entries.removeAll { isOurs($0) }
            entries.insert(ourCursorEntry(), at: 0)
            hooks[key] = entries
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

    private static func ourEntry() -> [String: Any] {
        ["type": "command", "command": hookPath(), "timeout": 120, "hookName": hookName]
    }

    private static func ourCursorEntry() -> [String: Any] {
        ["command": hookPath(), "timeout": 120, "hookName": hookName]
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        if entry["hookName"] as? String == hookName { return true }
        let cmd = entry["command"] as? String ?? ""
        return cmd.hasSuffix("agentnotch-hook")
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
