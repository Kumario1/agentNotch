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
        XCTAssertEqual(w[0].percent, 87.5)
        XCTAssertEqual(w[0].resetsAt, parseISO8601("2026-07-07T15:00:00Z"))
        XCTAssertEqual(w[1].percent, 60)
        XCTAssertEqual(w[2].percent, 95)
        XCTAssertNil(w[2].resetsAt)
        XCTAssertEqual(ClaudeLimits.windows(fromUsageResponse: Data("[]".utf8)), [])
    }

    func testClaudeEmailParsing() {
        let json = Data(#"{"oauthAccount":{"emailAddress":"me@example.com"},"otherStuff":1}"#.utf8)
        XCTAssertEqual(ClaudeLimits.email(fromClaudeJSON: json), "me@example.com")
        XCTAssertNil(ClaudeLimits.email(fromClaudeJSON: Data("{}".utf8)))
    }

    // MARK: Codex parsers

    private func codexLine(ts: String, primaryPct: Double, secondaryPct: Double) -> Data {
        Data("""
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10}},"rate_limits":{"primary":{"used_percent":\(primaryPct),"window_minutes":300,"resets_in_seconds":3600},"secondary":{"used_percent":\(secondaryPct),"window_minutes":10080,"resets_in_seconds":86400}}}}
        """.utf8)
    }

    func testCodexSnapshotParsing() {
        let s = CodexLimits.snapshot(from: codexLine(ts: "2026-07-07T10:00:00.000Z", primaryPct: 12.5, secondaryPct: 40))
        XCTAssertEqual(s?.windows.map(\.name), ["5H", "WEEK"])
        XCTAssertEqual(s?.windows[0].percent, 87.5)
        XCTAssertEqual(s?.asOf, parseISO8601("2026-07-07T10:00:00.000Z"))
        // resets_in_seconds is relative to the line timestamp
        XCTAssertEqual(s?.windows[0].resetsAt, parseISO8601("2026-07-07T11:00:00.000Z"))
        XCTAssertEqual(s?.windows[1].resetsAt, parseISO8601("2026-07-08T10:00:00.000Z"))
    }

    func testCodexSnapshotParsingAbsoluteResetEpoch() {
        let json = Data("""
        {"timestamp":"2026-07-06T21:27:58.240Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":96.0,"window_minutes":300,"resets_at":1783384679},"secondary":{"used_percent":49.0,"window_minutes":10080,"resets_at":1783894192}}}}
        """.utf8)
        let s = CodexLimits.snapshot(from: json)
        XCTAssertEqual(s?.windows[0].percent, 4)
        XCTAssertEqual(s?.windows[1].percent, 51)
        XCTAssertEqual(s?.windows[0].resetsAt, Date(timeIntervalSince1970: 1_783_384_679))
        XCTAssertEqual(s?.windows[1].resetsAt, Date(timeIntervalSince1970: 1_783_894_192))
    }

    func testCodexNonRateLimitLinesReturnNil() {
        XCTAssertNil(CodexLimits.snapshot(from: Data(#"{"timestamp":"2026-07-07T10:00:00Z","type":"event_msg","payload":{"type":"agent_message","message":"hi"}}"#.utf8)))
        XCTAssertNil(CodexLimits.snapshot(from: Data("not json".utf8)))
    }

    func testCodexNewerSnapshotWins() {
        let old = CodexLimits.snapshot(from: codexLine(ts: "2026-07-07T10:00:00.000Z", primaryPct: 10, secondaryPct: 10))!
        let new = CodexLimits.snapshot(from: codexLine(ts: "2026-07-07T11:00:00.000Z", primaryPct: 20, secondaryPct: 20))!
        let latest = [new, old].max { $0.asOf < $1.asOf }!
        XCTAssertEqual(latest.windows[0].percent, 80)
    }

    // MARK: Cursor parsers

    // Real payload shape: included-budget meter (spend/limit) drives the headline number.
    func testCursorPeriodUsageUsesIncludedBudget() {
        let json = Data("""
        {"billingCycleEnd":"1786116841000",
         "planUsage":{"totalSpend":1529,"remaining":471,"limit":2000,"totalPercentUsed":16.98}}
        """.utf8)
        let w = CursorLimits.windows(fromPeriodUsage: json)
        XCTAssertEqual(w.map(\.name), ["PLAN"])
        XCTAssertEqual(w[0].percent, 23.55, accuracy: 0.01, "471/2000 remaining, not totalPercentUsed")
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1_786_116_841))
    }

    func testCursorPeriodUsageDerivesRemainingFromSpendWhenAbsent() {
        let json = Data(#"{"planUsage":{"totalSpend":500,"limit":2000}}"#.utf8)
        let w = CursorLimits.windows(fromPeriodUsage: json)
        XCTAssertEqual(w[0].percent, 75, "remaining = (limit - totalSpend)/limit")
    }

    func testCursorPeriodUsageFallsBackToPercentWhenNoLimit() {
        let json = Data(#"{"planUsage":{"totalPercentUsed":40}}"#.utf8)
        let w = CursorLimits.windows(fromPeriodUsage: json)
        XCTAssertEqual(w.map(\.name), ["PLAN"])
        XCTAssertEqual(w[0].percent, 60)
    }

    func testCursorPeriodUsageEmptyAndClamped() {
        XCTAssertEqual(CursorLimits.windows(fromPeriodUsage: Data("{}".utf8)), [])
        XCTAssertEqual(CursorLimits.windows(fromPeriodUsage: Data("not json".utf8)), [])
        let over = Data(#"{"planUsage":{"remaining":-50,"limit":2000}}"#.utf8)
        XCTAssertEqual(CursorLimits.windows(fromPeriodUsage: over)[0].percent, 0,
                       "remaining must clamp to 0, never negative")
    }

    func testCodexEmailFromJWT() {
        // JWT with payload {"email":"me@example.com"} (unsigned, base64url segments)
        let payload = Data(#"{"email":"me@example.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let json = Data(#"{"tokens":{"id_token":"eyJhbGciOiJub25lIn0.\#(payload).sig"}}"#.utf8)
        XCTAssertEqual(CodexLimits.email(fromAuthJSON: json), "me@example.com")
        XCTAssertNil(CodexLimits.email(fromAuthJSON: Data("{}".utf8)))
    }
}
