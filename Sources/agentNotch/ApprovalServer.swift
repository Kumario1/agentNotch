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
    private let cursorPermissionsPath: String
    private let cursorCLIConfigPath: String
    private let acceptQueue = DispatchQueue(label: "agentNotch.approvals.accept", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "agentNotch.approvals.state", qos: .userInitiated)
    private let handlerQueue = DispatchQueue(label: "agentNotch.approvals.handler",
                                             qos: .userInitiated, attributes: .concurrent)
    private var source: DispatchSourceRead?
    private var serverFD: Int32 = -1
    private var waiters: [String: (ApprovalDecision, String?, [String: String]?) -> Void] = [:]
    private var alwaysAllow: Set<String> = []

    init(store: UsageStore,
         socketPath: String = ApprovalPaths.socket,
         alwaysAllowPath: String = ApprovalPaths.alwaysAllow,
         cursorPermissionsPath: String = CursorPermissions.defaultPath,
         cursorCLIConfigPath: String = CursorPermissions.defaultCLIConfigPath) {
        self.store = store
        self.socketPath = socketPath
        self.alwaysAllowPath = alwaysAllowPath
        self.cursorPermissionsPath = cursorPermissionsPath
        self.cursorCLIConfigPath = cursorCLIConfigPath
        loadAlwaysAllow()
    }

    func start() {
        acceptQueue.async { [weak self] in self?.listen() }
    }

    // Called on the main thread from the notch UI (button / key monitor).
    func decide(_ id: String, decision: ApprovalDecision, reason: String? = nil, answers: [String: String]? = nil) {
        let pending = store.pendingApprovals.first(where: { $0.id == id })
        let alwaysKey = decision == .always ? pending?.alwaysKey : nil
        // Cursor ignores hook `permission: allow` unless the command is already on its
        // terminal allowlist. Sync for future runs, and press the Run button on the card
        // Cursor is about to show (or already shows) so the pending command actually runs.
        if decision == .allow || decision == .always,
           let pending, pending.product == .cursor {
            CursorPermissions.syncAllow(command: pending.summary, permissionsPath: cursorPermissionsPath)
            CursorRunClicker.clickPendingRun()
        }
        store.pendingApprovals.removeAll { $0.id == id }

        stateQueue.async { [weak self] in
            guard let self else { return }
            if let alwaysKey {
                self.alwaysAllow.insert(alwaysKey)
                self.saveAlwaysAllow()
            }
            let effective: ApprovalDecision = decision == .always ? .allow : decision
            self.waiters.removeValue(forKey: id)?(effective, reason, answers)
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
        // The peer (hook) can die while we block for a decision; without this a late
        // writeDecision to the closed socket raises SIGPIPE and kills the whole app.
        var one: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
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

        // beforeShellExecution fires for all Cursor shell commands. Do not duplicate
        // Cursor's terminal or CLI Shell(...) allow rules in the notch.
        if request.product == .cursor,
           CursorPermissions.isAutoAllowed(
               command: request.summary,
               permissionsPath: cursorPermissionsPath,
               cliConfigPath: cursorCLIConfigPath,
               cwd: request.cwd) {
            writeDecision(clientFD, request: request, decision: .allow)
            return
        }

        let autoAllow = request.questions.isEmpty && stateQueue.sync { alwaysAllow.contains(request.alwaysKey) }
        if autoAllow {
            if request.product == .cursor {
                CursorPermissions.syncAllow(command: request.summary, permissionsPath: cursorPermissionsPath)
                CursorRunClicker.clickPendingRun()
            }
            writeDecision(clientFD, request: request, decision: .allow)
            return
        }

        // If the user answers the permission prompt in the terminal instead, Claude kills
        // the hook and the socket EOFs — that's our only signal to drop the stale card
        // instead of leaving the notch asking forever (issue #3).
        let hangup = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: stateQueue)
        hangup.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            guard recv(clientFD, &byte, 1, MSG_PEEK) <= 0 else { return }
            hangup.cancel()
            self?.dismissAbandoned(request.id)
        }
        hangup.resume()
        defer { hangup.cancel() }

        let (decision, reason, answers) = blockForDecision(request)
        // The allow path just synced the command into ~/.cursor/permissions.json (in
        // decide()). Cursor re-reads that file on change, but asynchronously — give the
        // watcher a beat so the pending command auto-runs instead of re-prompting in Cursor.
        if request.product == .cursor, decision == .allow {
            Thread.sleep(forTimeInterval: 0.4)
        }
        writeDecision(clientFD, request: request, decision: decision, reason: reason, answers: answers)
    }

    // Hook died before we decided (terminal answered / session ended): remove the card
    // and unblock the handler. The deny it writes lands on a dead socket, harmlessly.
    private func dismissAbandoned(_ id: String) {
        DispatchQueue.main.async { [store] in
            store.pendingApprovals.removeAll { $0.id == id }
        }
        // Already on stateQueue (hangup source's queue), so touch waiters directly.
        waiters.removeValue(forKey: id)?(.deny, nil, nil)
    }

    private func blockForDecision(_ request: ApprovalRequest) -> (ApprovalDecision, String?, [String: String]?) {
        let sem = DispatchSemaphore(value: 0)
        var result = ApprovalDecision.allow
        var resultReason: String? = nil
        var resultAnswers: [String: String]? = nil
        DispatchQueue.main.async { [store] in
            if !store.pendingApprovals.contains(where: { $0.id == request.id }) {
                store.pendingApprovals.append(request)
            }
        }
        stateQueue.async { [weak self] in
            self?.waiters[request.id] = { decision, reason, answers in
                result = decision
                resultReason = reason
                resultAnswers = answers
                sem.signal()
            }
        }
        sem.wait()
        stateQueue.async { [weak self] in self?.waiters.removeValue(forKey: request.id) }
        return (result, resultReason, resultAnswers)
    }

    // The hook owns the harness-specific output shapes; we hand it just the verdict
    // and, for a deny-with-feedback, the reason the user typed (fed back to the model).
    private func writeDecision(
        _ fd: Int32,
        request: ApprovalRequest,
        decision: ApprovalDecision,
        reason: String? = nil,
        answers: [String: String]? = nil
    ) {
        let effective: ApprovalDecision = decision == .always ? .allow : decision
        var obj: [String: Any] = ["decision": effective.rawValue]
        if let reason, !reason.isEmpty { obj["reason"] = reason }
        if let answers, !answers.isEmpty { obj["answers"] = answers }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var out = data
        out.append(0x0A)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
    }

    private func parseRequest(_ obj: [String: Any]) -> ApprovalRequest {
        let productRaw = obj["product"] as? String ?? "claude"
        let product = Product(rawValue: productRaw) ?? .claude
        let tool = obj["toolName"] as? String ?? obj["tool_name"] as? String ?? "tool"
        let questions = parseQuestions(tool: tool, obj: obj)
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
            alwaysKey: alwaysKey,
            questions: questions)
    }

    private func parseQuestions(tool: String, obj: [String: Any]) -> [ApprovalQuestion] {
        guard tool == "AskUserQuestion",
              let input = obj["tool_input"] as? [String: Any],
              let rawQuestions = input["questions"] as? [[String: Any]] else { return [] }

        return rawQuestions.map { raw in
            let header = raw["header"] as? String ?? ""
            let question = raw["question"] as? String ?? (header.isEmpty ? "Question" : header)
            let multiSelect = raw["multiSelect"] as? Bool ?? false
            let rawOptions = raw["options"] as? [[String: Any]] ?? []
            let options = rawOptions.compactMap { rawOption -> ApprovalOption? in
                guard let label = rawOption["label"] as? String, !label.isEmpty else { return nil }
                return ApprovalOption(
                    label: label,
                    description: rawOption["description"] as? String ?? "")
            }
            return ApprovalQuestion(
                question: question,
                header: header,
                multiSelect: multiSelect,
                options: options)
        }
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
