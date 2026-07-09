import XCTest
import Darwin
@testable import agentNotch

final class CursorPermissionsTests: XCTestCase {

    func testAllowlistEntryUsesRawFirstCommandToken() {
        XCTAssertEqual(CursorPermissions.allowlistEntry(for: "git status --short"), "git")
        // Cursor prefix-matches the raw command string, so full paths must stay full.
        XCTAssertEqual(CursorPermissions.allowlistEntry(for: "/usr/bin/sqlite3 foo.db"), "/usr/bin/sqlite3")
        XCTAssertEqual(CursorPermissions.allowlistEntry(for: "  npm install "), "npm")
        // Env assignments, quotes, and flags can never match as prefix entries.
        XCTAssertNil(CursorPermissions.allowlistEntry(for: #"HOOK="/tmp/x" some-cmd"#))
        XCTAssertNil(CursorPermissions.allowlistEntry(for: "FOO=bar make build"))
        XCTAssertNil(CursorPermissions.allowlistEntry(for: "--flag value"))
        XCTAssertNil(CursorPermissions.allowlistEntry(for: ""))
        XCTAssertNil(CursorPermissions.allowlistEntry(for: "   "))
    }

    func testSyncAllowAddsTerminalEntryWithoutWipingOtherKeys() throws {
        let path = "/tmp/an-perms-\(UUID().uuidString.prefix(8)).json"
        defer { unlink(path) }

        let seed: [String: Any] = [
            "mcpAllowlist": ["supabase:list_projects"],
            "terminalAllowlist": ["ls"],
            "autoRun": ["allow_instructions": ["keep me"]],
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seed, options: [.prettyPrinted])
        try seedData.write(to: URL(fileURLWithPath: path))

        XCTAssertTrue(CursorPermissions.syncAllow(command: "git status", permissionsPath: path))

        let root = try loadJSON(path)
        let terminal = root["terminalAllowlist"] as? [String] ?? []
        XCTAssertTrue(terminal.contains("ls"))
        XCTAssertTrue(terminal.contains("git"))
        XCTAssertEqual(root["mcpAllowlist"] as? [String], ["supabase:list_projects"])
        let autoRun = root["autoRun"] as? [String: Any]
        XCTAssertEqual(autoRun?["allow_instructions"] as? [String], ["keep me"])
    }

    func testIsAllowlistedUsesCursorPrefixSemantics() throws {
        let path = "/tmp/an-perms-\(UUID().uuidString.prefix(8)).json"
        defer { unlink(path) }

        let seed: [String: Any] = ["terminalAllowlist": ["git", "npm install"]]
        try JSONSerialization.data(withJSONObject: seed).write(to: URL(fileURLWithPath: path))

        XCTAssertTrue(CursorPermissions.isAllowlisted(command: "git status", permissionsPath: path))
        XCTAssertTrue(CursorPermissions.isAllowlisted(command: "git", permissionsPath: path))
        XCTAssertTrue(CursorPermissions.isAllowlisted(command: "npm install express", permissionsPath: path))
        XCTAssertFalse(CursorPermissions.isAllowlisted(command: "gitk", permissionsPath: path),
                       "prefix must stop at a token boundary")
        XCTAssertFalse(CursorPermissions.isAllowlisted(command: "npm run build", permissionsPath: path))
        XCTAssertFalse(CursorPermissions.isAllowlisted(command: "rm -rf /", permissionsPath: path))
        XCTAssertFalse(CursorPermissions.isAllowlisted(command: "git status", permissionsPath: "/tmp/nonexistent-\(UUID()).json"))
    }

    // Cursor auto-runs allowlisted commands without asking — the notch must not block them.
    func testAllowlistedCursorCommandSkipsNotchPrompt() throws {
        let short = String(UUID().uuidString.prefix(8))
        let socketPath = "/tmp/an-\(short).sock"
        let allowPath = "/tmp/an-\(short).json"
        let permsPath = "/tmp/an-perms-\(short).json"
        defer { unlink(socketPath); unlink(allowPath); unlink(permsPath) }

        let seed: [String: Any] = ["terminalAllowlist": ["git"]]
        try JSONSerialization.data(withJSONObject: seed).write(to: URL(fileURLWithPath: permsPath))

        let store = UsageStore()
        let server = ApprovalServer(
            store: store,
            socketPath: socketPath,
            alwaysAllowPath: allowPath,
            cursorPermissionsPath: permsPath)
        server.start()
        XCTAssertTrue(waitForFile(socketPath, timeout: 3), "server socket never bound")

        // No decide() call anywhere: the response must come back on its own.
        var responseText = ""
        let responseReceived = expectation(description: "auto allow without UI")
        DispatchQueue.global().async {
            responseText = ApprovalServerTests.roundTrip(socketPath: socketPath, request:
                #"{"id":"auto-\#(short)","product":"cursor","toolName":"Shell","command":"git status"}"#) ?? ""
            responseReceived.fulfill()
        }
        wait(for: [responseReceived], timeout: 3)
        XCTAssertTrue(responseText.contains("allow"), "expected auto-allow, got: \(responseText)")
        XCTAssertTrue(store.pendingApprovals.isEmpty, "notch must never have been prompted")
    }

    func testSyncAllowIsIdempotent() throws {
        let path = "/tmp/an-perms-\(UUID().uuidString.prefix(8)).json"
        defer { unlink(path) }

        XCTAssertTrue(CursorPermissions.syncAllow(command: "npm test", permissionsPath: path))
        XCTAssertTrue(CursorPermissions.syncAllow(command: "npm install", permissionsPath: path))

        let root = try loadJSON(path)
        let terminal = root["terminalAllowlist"] as? [String] ?? []
        XCTAssertEqual(terminal.filter { $0 == "npm" }.count, 1)
    }

    func testCursorAllowDecisionWritesPermissionsBeforeHookContinues() throws {
        let short = String(UUID().uuidString.prefix(8))
        let socketPath = "/tmp/an-\(short).sock"
        let allowPath = "/tmp/an-\(short).json"
        let permsPath = "/tmp/an-perms-\(short).json"
        defer { unlink(socketPath); unlink(allowPath); unlink(permsPath) }

        let store = UsageStore()
        let server = ApprovalServer(
            store: store,
            socketPath: socketPath,
            alwaysAllowPath: allowPath,
            cursorPermissionsPath: permsPath)
        server.start()
        XCTAssertTrue(waitForFile(socketPath, timeout: 3), "server socket never bound")

        let reqID = "req-\(short)"
        var responseText = ""
        let responseReceived = expectation(description: "hook receives a decision")
        DispatchQueue.global().async {
            responseText = ApprovalServerTests.roundTrip(socketPath: socketPath, request:
                #"{"id":"\#(reqID)","product":"cursor","toolName":"Shell","command":"swift test"}"#) ?? ""
            responseReceived.fulfill()
        }

        let decided = expectation(description: "user allowed")
        pollForPending(store: store) {
            server.decide(reqID, decision: .allow)
            decided.fulfill()
        }

        wait(for: [decided, responseReceived], timeout: 5)
        XCTAssertTrue(responseText.contains("allow"), "expected allow, got: \(responseText)")

        // Cursor only honors hook allow when the command is already on its allowlist.
        // Sync must happen before the hook response is written.
        let root = try loadJSON(permsPath)
        let terminal = root["terminalAllowlist"] as? [String] ?? []
        XCTAssertTrue(terminal.contains("swift"), "permissions.json must include swift, got: \(terminal)")
    }

    // MARK: - Helpers

    private func loadJSON(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

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
}
