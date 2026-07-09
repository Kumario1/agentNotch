import Foundation

// Cursor's beforeShellExecution hook returns `permission: allow`, but Cursor Auto-review
// often ignores that unless the command is already on its terminal allowlist
// (~/.cursor/permissions.json). Syncing the first token before we unblock the hook is
// what makes notch "Allow" actually run the command instead of leaving Cursor waiting.
enum CursorPermissions {
    static let defaultPath = NSString(string: "~/.cursor/permissions.json").expandingTildeInPath

    /// First token of a shell command, kept verbatim because Cursor matches allowlist
    /// entries as prefixes of the raw command string (`/usr/bin/git status` needs the
    /// entry `/usr/bin/git`, not `git`). Env assignments, quotes, and flags can never
    /// work as prefix entries, so those yield nil instead of polluting the allowlist.
    static func allowlistEntry(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        else { return nil }
        if token.contains("=") || token.contains("\"") || token.contains("'") || token.hasPrefix("-") {
            return nil
        }
        return token
    }

    /// True when the command already matches Cursor's terminal allowlist, using Cursor's
    /// prefix semantics (`git` matches `git status` but not `gitk`). Cursor auto-runs these
    /// without asking, so the notch must not prompt for them either.
    static func isAllowlisted(command: String, permissionsPath: String = defaultPath) -> Bool {
        guard let root = loadJSON(permissionsPath),
              let entries = root["terminalAllowlist"] as? [String] else { return false }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return entries.contains { matches(command: trimmed, entry: $0) }
    }

    private static func matches(command: String, entry: String) -> Bool {
        guard !entry.isEmpty, command.hasPrefix(entry) else { return false }
        if command.count == entry.count { return true }
        let next = command[command.index(command.startIndex, offsetBy: entry.count)]
        return next.isWhitespace
    }

    @discardableResult
    static func syncAllow(command: String, permissionsPath: String = defaultPath) -> Bool {
        guard let entry = allowlistEntry(for: command) else { return false }

        let fm = FileManager.default
        let dir = (permissionsPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var root = loadJSON(permissionsPath) ?? [:]
        var terminal = root["terminalAllowlist"] as? [String] ?? []
        if !terminal.contains(entry) {
            terminal.append(entry)
            terminal.sort()
            root["terminalAllowlist"] = terminal
            return writeJSON(root, to: permissionsPath)
        }
        // Ensure the file exists even when the entry was already present (first sync).
        if !fm.fileExists(atPath: permissionsPath) {
            root["terminalAllowlist"] = terminal
            return writeJSON(root, to: permissionsPath)
        }
        return true
    }

    private static func loadJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    @discardableResult
    private static func writeJSON(_ obj: [String: Any], to path: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
