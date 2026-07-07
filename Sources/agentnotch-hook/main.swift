import Foundation

private let socketPath = NSString(string: "~/.agentnotch/approvals.sock").expandingTildeInPath

// Hook helper: stdin JSON → Unix socket → stdout decision JSON. Fail-open on errors.
//
// Two jobs, in order:
//   1. Figure out which product fired the hook (Claude vs Cursor) from the payload
//      shape, so the notch never mislabels a Cursor prompt as "Claude Code".
//   2. Only bother the user for actions that actually need permission. Read-only
//      tools (and anything the agent already auto-runs) pass straight through
//      without touching the app — no socket round trip, no notch prompt.
@main
struct AgentNotchHook {
    static func main() {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        guard !stdin.isEmpty else { failOpen(); return }

        var payload = (try? JSONSerialization.jsonObject(with: stdin) as? [String: Any]) ?? [:]
        payload["id"] = payload["id"] as? String ?? UUID().uuidString

        let product = detectProduct(payload)
        payload["product"] = product

        let tool = toolName(payload)
        payload["toolName"] = tool
        payload["summary"] = summary(payload) ?? tool

        // Skip the prompt entirely for low-risk tools; let the action run.
        guard needsApproval(product: product, tool: tool, payload: payload) else {
            failOpen(product: product)
            return
        }

        guard let reqData = try? JSONSerialization.data(withJSONObject: payload) else {
            failOpen(product: product)
            return
        }

        guard let resp = roundTrip(reqData, product: product) else {
            failOpen(product: product)
            return
        }

        FileHandle.standardOutput.write(resp)
        if resp.last != 0x0A { FileHandle.standardOutput.write(Data([0x0A])) }
    }

    // MARK: - Payload interpretation

    // Cursor's common hook schema always carries fields Claude never sends
    // (cursor_version / conversation_id / generation_id / workspace_roots), and
    // its event names are lowerCamelCase. Claude's PreToolUse is exact-cased and
    // carries session_id. Check the unambiguous Cursor markers first.
    private static func detectProduct(_ p: [String: Any]) -> String {
        if let explicit = p["product"] as? String, !explicit.isEmpty { return explicit }
        if p["cursor_version"] != nil || p["conversation_id"] != nil
            || p["generation_id"] != nil || p["workspace_roots"] != nil {
            return "cursor"
        }
        if p["hook_event_name"] as? String == "PreToolUse"
            || p["session_id"] != nil || p["transcript_path"] != nil {
            return "claude"
        }
        // beforeShellExecution sends a bare command with no tool_name.
        if p["command"] != nil, p["tool_name"] == nil { return "cursor" }
        if p["tool_name"] != nil { return "claude" }
        return "claude"
    }

    private static func toolName(_ p: [String: Any]) -> String {
        if let t = p["toolName"] as? String, !t.isEmpty { return t }
        if let t = p["tool_name"] as? String, !t.isEmpty { return t }
        if p["command"] != nil { return "Shell" }
        return "tool"
    }

    private static func summary(_ p: [String: Any]) -> String? {
        if let s = p["summary"] as? String { return s }
        if let cmd = p["command"] as? String { return cmd }
        if let input = p["tool_input"] as? [String: Any] {
            if let cmd = input["command"] as? String { return cmd }
            if let file = input["file_path"] as? String { return file }
        }
        return p["tool_name"] as? String
    }

    // Read-only / low-risk tools run without a prompt. Anything that mutates state,
    // runs a command, hits an MCP server, or is unrecognized needs an approval —
    // unknown tools default to "ask" so a new capability is never silently allowed.
    private static let safeClaudeTools: Set<String> = [
        "read", "glob", "grep", "ls", "todowrite", "todoread", "notebookread",
        "webfetch", "websearch", "task", "bashoutput", "killbash", "killshell",
    ]

    private static func needsApproval(product: String, tool: String, payload: [String: Any]) -> Bool {
        switch product {
        case "cursor":
            // Cursor auto-runs safe commands inside its own sandbox and only asks the
            // user when a command must run with full access (`sandbox` == false).
            // Mirror that exactly: stay silent for sandboxed commands, prompt only for
            // the ones Cursor itself would stop and ask about.
            if let sandboxed = payload["sandbox"] as? Bool { return !sandboxed }
            return true
        case "claude":
            return !safeClaudeTools.contains(tool.lowercased())
        default:
            return true
        }
    }

    // MARK: - Socket round trip

    private static func roundTrip(_ request: Data, product: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let dst = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(dst, cstr, 104)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        guard connected == 0 else { return nil }

        var out = request
        out.append(0x0A)
        guard out.withUnsafeBytes({ write(fd, $0.baseAddress, out.count) }) == out.count else { return nil }

        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk.prefix(n))
            if buf.contains(0x0A) { break }
        }
        guard !buf.isEmpty else { return nil }

        guard let obj = try? JSONSerialization.jsonObject(with: buf) as? [String: Any] else { return buf }
        let decision = obj["decision"] as? String ?? "allow"
        return formatOutput(product: product, decision: decision)
    }

    private static func formatOutput(product: String, decision: String) -> Data? {
        let effective = decision == "always" ? "allow" : decision
        let obj: [String: Any]
        switch product {
        case "cursor":
            obj = ["permission": effective, "continue": true]
        case "claude":
            obj = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": effective,
                ],
            ]
        default:
            obj = ["decision": effective]
        }
        var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        data.append(0x0A)
        return data
    }

    private static func failOpen(product: String? = nil) {
        let p = product ?? "claude"
        if let data = formatOutput(product: p, decision: "allow") {
            FileHandle.standardOutput.write(data)
        }
    }
}
