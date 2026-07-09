import XCTest
import Darwin
@testable import agentNotch

final class ApprovalServerTests: XCTestCase {

    // Regression: the interactive "Allow" decision must reach a blocked hook client.
    // Previously handle()/decide() shared one serial queue, so the client's blocking
    // wait stalled the queue that delivered the decision -> permanent deadlock.
    func testInteractiveAllowReachesBlockedClient() throws {
        let short = String(UUID().uuidString.prefix(8))
        let socketPath = "/tmp/an-\(short).sock"
        let allowPath = "/tmp/an-\(short).json"
        let permsPath = "/tmp/an-perms-\(short).json"
        let cliConfigPath = "/tmp/an-cli-\(short).json"
        defer { unlink(socketPath); unlink(allowPath); unlink(permsPath); unlink(cliConfigPath) }

        let store = UsageStore()
        let server = ApprovalServer(store: store, socketPath: socketPath, alwaysAllowPath: allowPath,
                                    cursorPermissionsPath: permsPath, cursorCLIConfigPath: cliConfigPath)
        server.start()
        XCTAssertTrue(waitForFile(socketPath, timeout: 3), "server socket never bound")

        let reqID = "req-\(short)"
        var responseText = ""
        let responseReceived = expectation(description: "hook receives a decision")
        DispatchQueue.global().async {
            responseText = Self.roundTrip(socketPath: socketPath, request:
                #"{"id":"\#(reqID)","product":"cursor","toolName":"Shell","command":"ls -la"}"#) ?? ""
            responseReceived.fulfill()
        }

        // Simulate the user clicking Allow once the request is pending (on the main thread,
        // exactly like the notch UI does).
        let decided = expectation(description: "user allowed")
        pollForPending(store: store) {
            server.decide(reqID, decision: .allow)
            decided.fulfill()
        }

        wait(for: [decided, responseReceived], timeout: 5)
        XCTAssertTrue(responseText.contains("\"decision\""),
                      "expected a decision payload, got: \(responseText)")
        XCTAssertTrue(responseText.contains("allow"),
                      "expected an allow decision, got: \(responseText)")
        XCTAssertTrue(store.pendingApprovals.isEmpty, "pending approval should be cleared")
    }

    // Always-allow entries are honored without any user interaction.
    func testAlwaysAllowShortCircuitsWithoutUI() throws {
        let short = String(UUID().uuidString.prefix(8))
        let socketPath = "/tmp/an-\(short).sock"
        let allowPath = "/tmp/an-\(short).json"
        let permsPath = "/tmp/an-perms-\(short).json"
        let cliConfigPath = "/tmp/an-cli-\(short).json"
        defer { unlink(socketPath); unlink(allowPath); unlink(permsPath); unlink(cliConfigPath) }

        // Seed the allowlist with the key the server derives for this request.
        let alwaysKey = "cursor:Shell:ls -la"
        let seed = try JSONSerialization.data(withJSONObject: [alwaysKey])
        try seed.write(to: URL(fileURLWithPath: allowPath))

        let store = UsageStore()
        let server = ApprovalServer(store: store, socketPath: socketPath, alwaysAllowPath: allowPath,
                                    cursorPermissionsPath: permsPath, cursorCLIConfigPath: cliConfigPath)
        server.start()
        XCTAssertTrue(waitForFile(socketPath, timeout: 3), "server socket never bound")

        var responseText = ""
        let responseReceived = expectation(description: "auto decision")
        DispatchQueue.global().async {
            responseText = Self.roundTrip(socketPath: socketPath, request:
                #"{"id":"auto-\#(short)","product":"cursor","toolName":"Shell","command":"ls -la"}"#) ?? ""
            responseReceived.fulfill()
        }
        wait(for: [responseReceived], timeout: 5)
        XCTAssertTrue(responseText.contains("allow"), "expected auto-allow, got: \(responseText)")
    }

    // Deny-with-feedback must carry the user's reason back over the socket so the hook
    // can feed it to the model via PreToolUse's permissionDecisionReason.
    func testDenyWithReasonReachesBlockedClient() throws {
        let short = String(UUID().uuidString.prefix(8))
        let socketPath = "/tmp/an-\(short).sock"
        let allowPath = "/tmp/an-\(short).json"
        defer { unlink(socketPath); unlink(allowPath) }

        let store = UsageStore()
        let server = ApprovalServer(store: store, socketPath: socketPath, alwaysAllowPath: allowPath)
        server.start()
        XCTAssertTrue(waitForFile(socketPath, timeout: 3), "server socket never bound")

        let reqID = "req-\(short)"
        var responseText = ""
        let responseReceived = expectation(description: "hook receives a decision")
        DispatchQueue.global().async {
            responseText = Self.roundTrip(socketPath: socketPath, request:
                #"{"id":"\#(reqID)","product":"claude","toolName":"Bash","command":"rm -rf /"}"#) ?? ""
            responseReceived.fulfill()
        }

        let decided = expectation(description: "user denied with feedback")
        pollForPending(store: store) {
            server.decide(reqID, decision: .deny, reason: "too destructive, prefer git clean")
            decided.fulfill()
        }

        wait(for: [decided, responseReceived], timeout: 5)
        XCTAssertTrue(responseText.contains("\"deny\""), "expected a deny, got: \(responseText)")
        XCTAssertTrue(responseText.contains("too destructive"), "reason must ride back to the hook, got: \(responseText)")
    }

    func testAskUserQuestionParsesQuestionsAndReturnsAnswers() throws {
        let short = String(UUID().uuidString.prefix(8))
        let socketPath = "/tmp/an-\(short).sock"
        let allowPath = "/tmp/an-\(short).json"
        defer { unlink(socketPath); unlink(allowPath) }

        let store = UsageStore()
        let server = ApprovalServer(store: store, socketPath: socketPath, alwaysAllowPath: allowPath)
        server.start()
        XCTAssertTrue(waitForFile(socketPath, timeout: 3), "server socket never bound")

        let reqID = "req-\(short)"
        var responseText = ""
        let responseReceived = expectation(description: "hook receives question answers")
        DispatchQueue.global().async {
            responseText = Self.roundTrip(socketPath: socketPath, request:
                #"{"id":"\#(reqID)","product":"claude","toolName":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick one?","header":"Choice","multiSelect":false,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}}"#) ?? ""
            responseReceived.fulfill()
        }

        let pending = try XCTUnwrap(waitForPending(store: store, timeout: 3))
        XCTAssertEqual(pending.questions, [
            ApprovalQuestion(
                question: "Pick one?",
                header: "Choice",
                multiSelect: false,
                options: [
                    ApprovalOption(label: "A", description: "first"),
                    ApprovalOption(label: "B", description: "second"),
                ])
        ])

        server.decide(reqID, decision: .allow, answers: ["Pick one?": "B"])
        wait(for: [responseReceived], timeout: 5)

        let data = try XCTUnwrap(responseText.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["decision"] as? String, "allow")
        XCTAssertEqual((obj["answers"] as? [String: Any])?["Pick one?"] as? String, "B")
    }

    func testAskUserQuestionIgnoresAlwaysAllowEntry() throws {
        let short = String(UUID().uuidString.prefix(8))
        let socketPath = "/tmp/an-\(short).sock"
        let allowPath = "/tmp/an-\(short).json"
        defer { unlink(socketPath); unlink(allowPath) }

        let alwaysKey = "claude:AskUserQuestion:AskUserQuestion"
        let seed = try JSONSerialization.data(withJSONObject: [alwaysKey])
        try seed.write(to: URL(fileURLWithPath: allowPath))

        let store = UsageStore()
        let server = ApprovalServer(store: store, socketPath: socketPath, alwaysAllowPath: allowPath)
        server.start()
        XCTAssertTrue(waitForFile(socketPath, timeout: 3), "server socket never bound")

        let reqID = "req-\(short)"
        var responseText = ""
        let responseReceived = expectation(description: "hook receives question decision")
        DispatchQueue.global().async {
            responseText = Self.roundTrip(socketPath: socketPath, request:
                #"{"id":"\#(reqID)","product":"claude","toolName":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick one?","options":[{"label":"A"},{"label":"B"}]}]}}"#) ?? ""
            responseReceived.fulfill()
        }

        let pending = try XCTUnwrap(waitForPending(store: store, timeout: 1),
                                   "question prompts must still reach the UI even when their always-allow key is present")
        XCTAssertEqual(pending.id, reqID)
        server.decide(reqID, decision: .allow, answers: ["Pick one?": "A"])

        wait(for: [responseReceived], timeout: 5)
        XCTAssertTrue(responseText.contains("\"answers\""), "expected selected answer, got: \(responseText)")
    }

    // MARK: - Helpers

    private func pollForPending(store: UsageStore, then action: @escaping () -> Void) {
        func tick() {
            if store.pendingApprovals.first != nil { action(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: tick)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: tick)
    }

    private func waitForFile(_ path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            usleep(20_000)
        }
        return FileManager.default.fileExists(atPath: path)
    }

    private func waitForPending(store: UsageStore, timeout: TimeInterval) -> ApprovalRequest? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pending = store.pendingApprovals.first { return pending }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return store.pendingApprovals.first
    }

    static func roundTrip(socketPath: String, request: String) -> String? {
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
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0 else { return nil }

        var out = Data(request.utf8)
        out.append(0x0A)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }

        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk.prefix(n))
            if buf.contains(0x0A) { break }
        }
        return String(data: buf, encoding: .utf8)
    }
}
