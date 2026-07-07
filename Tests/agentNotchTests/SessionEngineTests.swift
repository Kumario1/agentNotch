import XCTest
@testable import agentNotch

final class SessionEngineTests: XCTestCase {

    func testClaudeSessionParsing() {
        var s = SessionParsing.empty(path: "/tmp/proj/session.jsonl", product: .claude, modifiedAt: .distantPast)
        SessionParsing.apply(Data("""
        {"type":"assistant","timestamp":"2026-07-07T10:00:00.000Z","cwd":"/tmp/Fable","sessionId":"abc","message":{"role":"assistant","usage":{"input_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5,"output_tokens":7},"content":[{"type":"tool_use","name":"Bash"}]}}
        """.utf8), product: .claude, to: &s)

        XCTAssertEqual(s.title, "Fable")
        XCTAssertEqual(s.sessionID, "abc")
        XCTAssertEqual(s.detail, "Running Bash")
        XCTAssertEqual(s.inputTokens, 10)
        XCTAssertEqual(s.outputTokens, 7)
    }

    func testCodexSessionParsingUsesLatestTotals() {
        var s = SessionParsing.empty(path: "/tmp/rollout.jsonl", product: .codex, modifiedAt: .distantPast)
        SessionParsing.apply(Data("""
        {"timestamp":"2026-07-07T10:00:00.000Z","payload":{"type":"turn_context","cwd":"/tmp/Playground","turn_id":"t1"}}
        """.utf8), product: .codex, to: &s)
        SessionParsing.apply(Data("""
        {"timestamp":"2026-07-07T10:01:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2500000,"output_tokens":16000}}}}
        """.utf8), product: .codex, to: &s)
        SessionParsing.apply(Data("""
        {"timestamp":"2026-07-07T10:02:00.000Z","payload":{"type":"function_call","name":"exec_command"}}
        """.utf8), product: .codex, to: &s)

        XCTAssertEqual(s.title, "Playground")
        XCTAssertEqual(s.sessionID, "t1")
        XCTAssertEqual(s.detail, "Running exec_command")
        XCTAssertEqual(s.inputTokens, 2_500_000)
        XCTAssertEqual(s.outputTokens, 16_000)
        XCTAssertTrue(s.isActive)
    }

    func testCodexTaskCompleteMarksSessionInactive() {
        var s = SessionParsing.empty(path: "/tmp/rollout.jsonl", product: .codex, modifiedAt: .distantPast)
        SessionParsing.apply(Data(#"{"timestamp":"2026-07-07T10:00:00.000Z","payload":{"type":"task_started"}}"#.utf8), product: .codex, to: &s)
        XCTAssertTrue(s.isActive)

        SessionParsing.apply(Data(#"{"timestamp":"2026-07-07T10:01:00.000Z","payload":{"type":"task_complete"}}"#.utf8), product: .codex, to: &s)
        XCTAssertFalse(s.isActive)

        SessionParsing.apply(Data(#"{"timestamp":"2026-07-07T10:02:00.000Z","payload":{"type":"task_started"}}"#.utf8), product: .codex, to: &s)
        XCTAssertTrue(s.isActive)
    }

    func testClaudeStopMarkersMarkSessionInactive() {
        var s = SessionParsing.empty(path: "/tmp/proj/session.jsonl", product: .claude, modifiedAt: .distantPast)
        SessionParsing.apply(Data("""
        {"type":"user","timestamp":"2026-07-07T10:00:00.000Z","message":{"role":"user","content":"hi"}}
        """.utf8), product: .claude, to: &s)
        XCTAssertTrue(s.isActive)

        SessionParsing.apply(Data(#"{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-07-07T10:01:00.000Z"}"#.utf8), product: .claude, to: &s)
        XCTAssertFalse(s.isActive)
    }

    func testCursorSessionParsing() {
        var s = SessionParsing.empty(path: "/tmp/.cursor/projects/foo/agent-transcripts/u/u.jsonl", product: .cursor, modifiedAt: .distantPast)
        SessionParsing.apply(Data("""
        {"role":"user","message":{"content":[{"type":"text","text":"fix the login bug"}]}}
        """.utf8), product: .cursor, to: &s)
        SessionParsing.apply(Data("""
        {"role":"assistant","message":{"content":[{"type":"tool_call","name":"Shell","toolName":"Shell"}]}}
        """.utf8), product: .cursor, to: &s)

        XCTAssertEqual(s.title, "foo")
        XCTAssertEqual(s.detail, "Running Shell")
        XCTAssertTrue(s.isActive)
    }

    func testCursorTurnEndedMarksSessionInactive() {
        var s = SessionParsing.empty(path: "/tmp/.cursor/projects/foo/agent-transcripts/u/u.jsonl", product: .cursor, modifiedAt: .distantPast)
        SessionParsing.apply(Data(#"{"role":"assistant","message":{"content":[{"type":"text","text":"working"}]}}"#.utf8), product: .cursor, to: &s)
        XCTAssertTrue(s.isActive)

        SessionParsing.apply(Data(#"{"type":"turn_ended","status":"success"}"#.utf8), product: .cursor, to: &s)
        XCTAssertFalse(s.isActive, "turn_ended must retire the session so only working ones stay listed")

        // A fresh user turn revives it.
        SessionParsing.apply(Data(#"{"role":"user","message":{"content":[{"type":"text","text":"again"}]}}"#.utf8), product: .cursor, to: &s)
        XCTAssertTrue(s.isActive)
    }

    // Real Cursor transcripts use type "tool_use" with an absolute `input.path` and carry
    // no cwd; the parser must recover the project cwd/title from the slugged transcript path.
    func testCursorRealFormatRecoversCwdAndTitle() {
        let path = "/Users/me/.cursor/projects/Users-me-Documents-sentinel-dev/agent-transcripts/u/u.jsonl"
        var s = SessionParsing.empty(path: path, product: .cursor, modifiedAt: .distantPast)

        // Before any tool call, the hyphenated project name must not be mangled to "dev".
        XCTAssertEqual(s.title, "sentinel-dev")

        SessionParsing.apply(Data("""
        {"role":"assistant","message":{"content":[{"type":"text","text":"Let me look"},{"type":"tool_use","name":"Read","input":{"path":"/Users/me/Documents/sentinel-dev/README.md"}}]}}
        """.utf8), product: .cursor, to: &s)

        XCTAssertEqual(s.cwd, "/Users/me/Documents/sentinel-dev")
        XCTAssertEqual(s.title, "sentinel-dev")
        XCTAssertEqual(s.detail, "Running Read")
        XCTAssertTrue(s.isActive)
    }
}
