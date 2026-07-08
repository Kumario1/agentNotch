import Foundation

// Which Claude sessions' terminals are still open. Claude runs as
// `claude --session-id <uuid>`, and that uuid is the transcript filename — so the
// process argv names its exact session. That's precise per-session liveness: it
// tells apart several sessions in ONE folder, which a cwd match can't.
//
// ponytail: Codex runs one shared `app-server` and Cursor's agent is in-app —
// neither names a session in argv, so those fall back to working-only (see
// SessionEngine.publishable).
enum SessionLiveness {
    // Session UUIDs of every running `claude --session-id <uuid>`.
    // Returns nil if the probe itself failed, so a transient hiccup never flips
    // live sessions to "dead" (ps -axww always prints something on success).
    static func liveClaudeSessionIDs() -> Set<String>? {
        let out = run("/bin/ps", ["-axww", "-o", "args="])
        guard !out.isEmpty else { return nil }
        var ids = Set<String>()
        for line in out.split(whereSeparator: \.isNewline) {
            guard line.contains("/claude"), let r = line.range(of: "--session-id") else { continue }
            let id = line[r.upperBound...].drop { $0 == " " || $0 == "=" }.prefix { !$0.isWhitespace }
            if !id.isEmpty { ids.insert(String(id)) }
        }
        return ids
    }

    // ponytail: mirrors NotchView.shellOut; kept private here to avoid coupling the
    // engine to the view file.
    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
