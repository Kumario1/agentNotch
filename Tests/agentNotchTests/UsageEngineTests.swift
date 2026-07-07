import XCTest
@testable import agentNotch

// Feeds synthetic JSONL lines through the parser + window math and asserts the 5h / 7d sums.
// This is the one check that fails if parsing or the rolling-window logic breaks.
final class UsageEngineTests: XCTestCase {

    private func line(_ ts: String, _ i: Int, _ o: Int, _ cc: Int, _ cr: Int) -> Data {
        Data("""
        {"type":"assistant","timestamp":"\(ts)","message":{"usage":{"input_tokens":\(i),"output_tokens":\(o),"cache_creation_input_tokens":\(cc),"cache_read_input_tokens":\(cr)}}}
        """.utf8)
    }

    func testWindowSums() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = iso.date(from: "2026-07-07T12:00:00.000Z")!

        let lines: [Data] = [
            line("2026-06-29T12:00:00.000Z", 9999, 0, 0, 0),   // 8d ago: outside both windows
            line("2026-07-01T12:00:00.000Z", 1000, 0, 0, 0),   // 6d ago: in 7d, not in 5h
            line("2026-07-07T10:00:00.000Z", 10, 200, 200, 90),// 2h ago: 500 tokens, in both
            line("2026-07-07T11:00:00.000Z", 100, 100, 50, 50),// 1h ago: 300 tokens, in both
            Data("{\"type\":\"user\",\"timestamp\":\"2026-07-07T11:30:00.000Z\"}".utf8), // no usage: skip
            Data("not json".utf8),                              // malformed: skip
        ]

        let events = lines.compactMap { UsageEngine.event(from: $0) }
        XCTAssertEqual(events.count, 4, "only the four assistant-usage lines parse")

        let r = UsageEngine.compute(events: events, now: now)
        XCTAssertEqual(r.seven, 1800, "7d sum excludes the 8-day-old line")
        XCTAssertEqual(r.five, 800, "5h window anchors at the 2h-ago event")
        XCTAssertEqual(r.windowStart, iso.date(from: "2026-07-07T10:00:00.000Z"))
        XCTAssertEqual(r.reset, iso.date(from: "2026-07-07T15:00:00.000Z"))
    }

    func testExpiredFiveHourWindow() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = iso.date(from: "2026-07-07T12:00:00.000Z")!
        // Only stale activity: 7d still counts, 5h window has expired.
        let events = [UsageEvent(date: iso.date(from: "2026-07-05T00:00:00.000Z")!, tokens: 700)]
        let r = UsageEngine.compute(events: events, now: now)
        XCTAssertEqual(r.seven, 700)
        XCTAssertEqual(r.five, 0)
        XCTAssertNil(r.reset)
    }
}
