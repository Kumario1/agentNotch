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
}
