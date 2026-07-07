import XCTest
@testable import agentNotch

final class LimitsTests: XCTestCase {

    // MARK: Config

    func testConfigDefaults() {
        let c = AppConfig.parse(nil)
        XCTAssertEqual(c.claudeDirs.map(\.lastPathComponent), [".claude"])
        XCTAssertEqual(c.codexDirs.map(\.lastPathComponent), [".codex"])
    }

    func testConfigCustomDirsAndTildeExpansion() {
        let json = Data(#"{"claude": ["~/.claude", "~/claude-work"], "codex": ["~/.codex"]}"#.utf8)
        let c = AppConfig.parse(json)
        XCTAssertEqual(c.claudeDirs.count, 2)
        XCTAssertFalse(c.claudeDirs[1].path.contains("~"), "tilde must be expanded")
        XCTAssertTrue(c.claudeDirs[1].path.hasSuffix("/claude-work"))
    }

    func testConfigMalformedFallsBackToDefaults() {
        let c = AppConfig.parse(Data("not json".utf8))
        XCTAssertEqual(c.claudeDirs.map(\.lastPathComponent), [".claude"])
    }

    // MARK: ISO helper

    func testParseISO8601BothVariants() {
        XCTAssertNotNil(parseISO8601("2026-07-07T10:00:00.000Z"))
        XCTAssertNotNil(parseISO8601("2026-07-07T10:00:00Z"))
        XCTAssertNil(parseISO8601("yesterday"))
    }

    // MARK: Claude parsers

    func testClaudeCredentialsParsing() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"r","expiresAt":1783000000000,"subscriptionType":"max"}}"#.utf8)
        let c = ClaudeLimits.credentials(from: json)
        XCTAssertEqual(c?.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(c?.expiresAt, Date(timeIntervalSince1970: 1_783_000_000))
        XCTAssertNil(ClaudeLimits.credentials(from: Data("{}".utf8)))
    }

    func testClaudeUsageResponseParsing() {
        let json = Data("""
        {"five_hour":{"utilization":12.5,"resets_at":"2026-07-07T15:00:00Z"},
         "seven_day":{"utilization":40,"resets_at":"2026-07-12T00:00:00.000Z"},
         "seven_day_opus":{"utilization":5,"resets_at":null},
         "future_unknown_window":{"weird":true}}
        """.utf8)
        let w = ClaudeLimits.windows(fromUsageResponse: json)
        XCTAssertEqual(w.map(\.name), ["5H", "7D", "OPUS"])
        XCTAssertEqual(w[0].percent, 12.5)
        XCTAssertEqual(w[0].resetsAt, parseISO8601("2026-07-07T15:00:00Z"))
        XCTAssertEqual(w[1].percent, 40)
        XCTAssertNil(w[2].resetsAt)
        XCTAssertEqual(ClaudeLimits.windows(fromUsageResponse: Data("[]".utf8)), [])
    }

    func testClaudeEmailParsing() {
        let json = Data(#"{"oauthAccount":{"emailAddress":"me@example.com"},"otherStuff":1}"#.utf8)
        XCTAssertEqual(ClaudeLimits.email(fromClaudeJSON: json), "me@example.com")
        XCTAssertNil(ClaudeLimits.email(fromClaudeJSON: Data("{}".utf8)))
    }
}
