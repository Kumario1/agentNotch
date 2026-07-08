import Foundation

// Which sessions' terminals are still open. The transcript can't tell us (an
// idle-but-open session writes nothing, and the CLI doesn't hold the .jsonl
// open), so we read the process table: a session is "alive" while a process of
// its product runs with the session's cwd.
//
// ponytail: cwd-keyed — two sessions sharing one cwd stay alive until BOTH
// terminals close. Same ceiling the terminal-focus code in NotchView accepts.
// ponytail: Codex.app / Cursor run their agent at "/" (not the project dir), so
// their idle sessions fall back to working-only until we have a better signal.
enum SessionLiveness {
    // "<product.rawValue>|<cwd>" for every running agent CLI. One ps + one lsof.
    static func liveKeys() -> Set<String> {
        let byComm: [String: Product] = ["claude": .claude, "codex": .codex, "cursor-agent": .cursor]
        var product: [pid_t: Product] = [:]
        for line in run("/bin/ps", ["-axo", "pid=,comm="]).split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = pid_t(t[..<sp]) else { continue }
            let comm = URL(fileURLWithPath: String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces)).lastPathComponent
            if let p = byComm[comm] { product[pid] = p }
        }
        guard !product.isEmpty else { return [] }

        // lsof -Fpn emits "p<pid>" then "n<cwd>" pairs; pair each live cwd with its product.
        let pids = product.keys.map(String.init).joined(separator: ",")
        var keys = Set<String>()
        var cur: pid_t?
        for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pids, "-Fpn"]).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") { cur = pid_t(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid = cur, let p = product[pid] {
                keys.insert(key(product: p, cwd: String(line.dropFirst())))
            }
        }
        return keys
    }

    static func key(product: Product, cwd: String) -> String { "\(product.rawValue)|\(cwd)" }

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
