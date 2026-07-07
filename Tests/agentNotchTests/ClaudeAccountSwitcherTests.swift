import XCTest
@testable import agentNotch

final class ClaudeAccountSwitcherTests: XCTestCase {

    private func credJSON(token: String) -> Data {
        Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"r","expiresAt":1783000000000}}"#.utf8)
    }

    func testNamespacedServiceUsesSha256Prefix() {
        let dir = URL(fileURLWithPath: "/Users/me/.claude-work", isDirectory: true)
        let expected = ClaudeAccountSwitching.sha256Hex(dir.path).prefix(8)
        XCTAssertEqual(ClaudeAccountSwitching.namespacedService(for: dir), "Claude Code-credentials-\(expected)")
    }

    func testSha256HexIsDeterministic() {
        let a = ClaudeAccountSwitching.sha256Hex("/Users/me/.claude")
        let b = ClaudeAccountSwitching.sha256Hex("/Users/me/.claude")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
    }

    func testAccountIDFormat() {
        let dir = URL(fileURLWithPath: "/tmp/claude-work", isDirectory: true)
        XCTAssertEqual(ClaudeAccountSwitching.accountID(for: dir), "claude:/tmp/claude-work")
    }

    func testMatchingDirFindsTokenOwner() {
        let work = "/Users/me/claude-work"
        let personal = "/Users/me/.claude"
        let byPath = [
            work: credJSON(token: "token-work"),
            personal: credJSON(token: "token-personal"),
        ]
        XCTAssertEqual(ClaudeAccountSwitching.matchingDir(accessToken: "token-work", credentialsByPath: byPath), work)
        XCTAssertEqual(ClaudeAccountSwitching.matchingDir(accessToken: "token-personal", credentialsByPath: byPath), personal)
        XCTAssertNil(ClaudeAccountSwitching.matchingDir(accessToken: "missing", credentialsByPath: byPath))
    }

    func testDirForAccountIDAmongConfiguredDirs() {
        let dirs = [
            URL(fileURLWithPath: "/Users/me/.claude", isDirectory: true),
            URL(fileURLWithPath: "/Users/me/claude-work", isDirectory: true),
        ]
        let id = ClaudeAccountSwitching.accountID(for: dirs[1])
        XCTAssertEqual(ClaudeAccountSwitching.dir(forAccountID: id, among: dirs)?.path, dirs[1].path)
        XCTAssertNil(ClaudeAccountSwitching.dir(forAccountID: "claude:/nope", among: dirs))
    }
}
