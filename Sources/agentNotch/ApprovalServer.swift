import Foundation

enum ApprovalPaths {
    static let home = NSString(string: "~/.agentnotch").expandingTildeInPath
    static let socket = "\(home)/approvals.sock"
    static let alwaysAllow = "\(home)/always-allow.json"
}

// Unix socket server: hook connects, sends one request JSON, blocks for a decision JSON back.
//
// Concurrency: each client is handled on the global concurrent queue so its blocking
// wait for a user decision never stalls anything else. `acceptQueue` (serial) owns the
// listen socket, and `stateQueue` (serial) guards `waiters`/`alwaysAllow` with only
// fast, non-blocking work — so a decision can always be delivered while a client blocks.
final class ApprovalServer {
    private let store: UsageStore
    private let socketPath: String
    private let alwaysAllowPath: String
    private let acceptQueue = DispatchQueue(label: "agentNotch.approvals.accept", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "agentNotch.approvals.state", qos: .userInitiated)
    private let handlerQueue = DispatchQueue(label: "agentNotch.approvals.handler",
                                             qos: .userInitiated, attributes: .concurrent)
    private var source: DispatchSourceRead?
    private var serverFD: Int32 = -1
    private var waiters: [String: (ApprovalDecision) -> Void] = [:]
    private var alwaysAllow: Set<String> = []

    init(store: UsageStore,
         socketPath: String = ApprovalPaths.socket,
         alwaysAllowPath: String = ApprovalPaths.alwaysAllow) {
        self.store = store
        self.socketPath = socketPath
        self.alwaysAllowPath = alwaysAllowPath
        loadAlwaysAllow()
    }

    func start() {
        acceptQueue.async { [weak self] in self?.listen() }
    }

    // Called on the main thread from the notch UI (button / key monitor).
    func decide(_ id: String, decision: ApprovalDecision) {
        let alwaysKey = decision == .always
            ? store.pendingApprovals.first(where: { $0.id == id })?.alwaysKey
            : nil
        store.pendingApprovals.removeAll { $0.id == id }

        stateQueue.async { [weak self] in
            guard let self else { return }
            if let alwaysKey {
                self.alwaysAllow.insert(alwaysKey)
                self.saveAlwaysAllow()
            }
            let effective: ApprovalDecision = decision == .always ? .allow : decision
            self.waiters.removeValue(forKey: id)?(effective)
        }
    }

    // MARK: - Socket

    private func listen() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        unlink(socketPath)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let dst = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(dst, cstr, 104)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, len)
            }
        }
        guard bound == 0, Darwin.listen(serverFD, 8) == 0 else { close(serverFD); return }

        let src = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    private func acceptOne() {
        let client = accept(serverFD, nil, nil)
        guard client >= 0 else { return }
        // Handle on a concurrent queue: this call blocks until the user decides, and
        // must not stall the accept source or the state queue that delivers decisions.
        handlerQueue.async { [weak self] in self?.handle(clientFD: client) }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(clientFD, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk.prefix(n))
            if buf.contains(0x0A) { break }
        }
        guard !buf.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: buf) as? [String: Any] else { return }

        let request = parseRequest(obj)
        let autoAllow = stateQueue.sync { alwaysAllow.contains(request.alwaysKey) }
        if autoAllow {
            writeDecision(clientFD, request: request, decision: .allow)
            return
        }

        let decision = blockForDecision(request)
        writeDecision(clientFD, request: request, decision: decision)
    }

    private func blockForDecision(_ request: ApprovalRequest) -> ApprovalDecision {
        let sem = DispatchSemaphore(value: 0)
        var result = ApprovalDecision.allow
        DispatchQueue.main.async { [store] in
            if !store.pendingApprovals.contains(where: { $0.id == request.id }) {
                store.pendingApprovals.append(request)
            }
        }
        stateQueue.async { [weak self] in
            self?.waiters[request.id] = { decision in
                result = decision
                sem.signal()
            }
        }
        sem.wait()
        stateQueue.async { [weak self] in self?.waiters.removeValue(forKey: request.id) }
        return result
    }

    // The hook owns the harness-specific output shapes; we hand it just the verdict.
    private func writeDecision(_ fd: Int32, request: ApprovalRequest, decision: ApprovalDecision) {
        let effective: ApprovalDecision = decision == .always ? .allow : decision
        guard let data = try? JSONSerialization.data(withJSONObject: ["decision": effective.rawValue]) else { return }
        var out = data
        out.append(0x0A)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
    }

    private func parseRequest(_ obj: [String: Any]) -> ApprovalRequest {
        let productRaw = obj["product"] as? String ?? "claude"
        let product = Product(rawValue: productRaw) ?? .claude
        let tool = obj["toolName"] as? String ?? obj["tool_name"] as? String ?? "tool"
        let summary = obj["summary"] as? String ?? obj["command"] as? String ?? tool
        let cwd = obj["cwd"] as? String
        let sessionTitle: String
        if let cwd, !cwd.isEmpty {
            sessionTitle = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            sessionTitle = product.rawValue.capitalized
        }
        // Key on the whole command, not a prefix: two different commands sharing the
        // first N chars must not auto-allow each other once one is "always allowed".
        let alwaysKey = "\(product.rawValue):\(tool):\(summary)"
        return ApprovalRequest(
            id: obj["id"] as? String ?? UUID().uuidString,
            product: product,
            sessionTitle: sessionTitle,
            toolName: tool,
            summary: summary,
            cwd: cwd,
            receivedAt: Date(),
            alwaysKey: alwaysKey)
    }

    // MARK: - Always allow persistence

    private func loadAlwaysAllow() {
        guard let data = FileManager.default.contents(atPath: alwaysAllowPath),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return }
        alwaysAllow = Set(arr)
    }

    private func saveAlwaysAllow() {
        let data = (try? JSONSerialization.data(withJSONObject: Array(alwaysAllow).sorted())) ?? Data("[]".utf8)
        try? data.write(to: URL(fileURLWithPath: alwaysAllowPath), options: .atomic)
    }
}
