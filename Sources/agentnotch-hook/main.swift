import Foundation

private let socketPath = NSString(string: "~/.agentnotch/approvals.sock").expandingTildeInPath

// Hook helper: stdin JSON → Unix socket → stdout decision JSON. Fail-open on errors.
@main
struct AgentNotchHook {
    static func main() {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        guard !stdin.isEmpty else { failOpen(); return }

        var payload = (try? JSONSerialization.jsonObject(with: stdin) as? [String: Any]) ?? [:]
        payload["id"] = payload["id"] as? String ?? UUID().uuidString

        if payload["product"] == nil {
            if payload["hook_event_name"] as? String == "PreToolUse"
                || payload["tool_name"] != nil {
                payload["product"] = "claude"
            } else if payload["command"] != nil {
                payload["product"] = "cursor"
            }
        }
        if payload["toolName"] == nil {
            payload["toolName"] = payload["tool_name"] as? String
                ?? (payload["command"] != nil ? "Shell" : "tool")
        }
        if payload["summary"] == nil {
            if let cmd = payload["command"] as? String {
                payload["summary"] = cmd
            } else if let input = payload["tool_input"] as? [String: Any],
                      let cmd = input["command"] as? String {
                payload["summary"] = cmd
            } else if let name = payload["tool_name"] as? String {
                payload["summary"] = name
            }
        }

        guard let reqData = try? JSONSerialization.data(withJSONObject: payload) else {
            failOpen(product: payload["product"] as? String)
            return
        }

        guard let resp = roundTrip(reqData) else {
            failOpen(product: payload["product"] as? String)
            return
        }

        FileHandle.standardOutput.write(resp)
        if resp.last != 0x0A { FileHandle.standardOutput.write(Data([0x0A])) }
    }

    private static func roundTrip(_ request: Data) -> Data? {
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
        let product = payloadString(obj, key: "product") ?? "claude"
        let decision = payloadString(obj, key: "decision") ?? "allow"
        return formatOutput(product: product, decision: decision)
    }

    private static func payloadString(_ obj: [String: Any], key: String) -> String? {
        obj[key] as? String
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
