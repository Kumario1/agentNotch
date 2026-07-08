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

    func testDetailStripsHarnessMetaTagsAndANSI() {
        var s = SessionParsing.empty(path: "/tmp/proj/session.jsonl", product: .claude, modifiedAt: .distantPast)
        SessionParsing.apply(Data("""
        {"type":"user","timestamp":"2026-07-07T10:00:00.000Z","message":{"role":"user","content":"<local-command-stdout>Set model to \\u001b[1mFable 5\\u001b[22m</local-command-stdout>"}}
        """.utf8), product: .claude, to: &s)

        XCTAssertEqual(s.detail, "Set model to Fable 5")
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

    func testLastPromptKeepsSessionActiveDuringThinkingGap() {
        // `last-prompt` is written at the START of a turn — it carries the just-submitted
        // prompt, has no timestamp, and is followed by a possibly-long "thinking" gap
        // before the first assistant line. It must NOT retire the session, or the row
        // vanishes to "No sessions" mid-turn.
        var s = SessionParsing.empty(path: "/tmp/proj/session.jsonl", product: .claude, modifiedAt: .distantPast)
        SessionParsing.apply(Data("""
        {"type":"user","timestamp":"2026-07-07T10:00:00.000Z","message":{"role":"user","content":"push all changes"}}
        """.utf8), product: .claude, to: &s)
        XCTAssertTrue(s.isActive)

        SessionParsing.apply(Data(#"{"type":"last-prompt","lastPrompt":"push all changes","sessionId":"abc"}"#.utf8), product: .claude, to: &s)
        XCTAssertTrue(s.isActive, "last-prompt starts a turn; it must not retire the session during the pre-first-token think")
        XCTAssertEqual(s.detail, "push all changes")
    }

    func testEndTurnMarksSessionIdle() {
        var s = SessionParsing.empty(path: "/tmp/proj/session.jsonl", product: .claude, modifiedAt: .distantPast)
        SessionParsing.apply(Data(#"{"type":"user","timestamp":"2026-07-07T10:00:00.000Z","message":{"role":"user","content":"go"}}"#.utf8), product: .claude, to: &s)
        XCTAssertTrue(s.isActive)

        SessionParsing.apply(Data(#"{"type":"assistant","timestamp":"2026-07-07T10:01:00.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#.utf8), product: .claude, to: &s)
        XCTAssertFalse(s.isActive, "end_turn ends the working state")
        XCTAssertEqual(s.detail, "Idle", "idle rows carry a clear cue while the terminal stays open")
    }

    func testPublishableShowsOnlyLiveClaudeSessions() {
        func make(_ id: String, active: Bool, alive: Bool, at t: TimeInterval) -> AgentSession {
            var s = SessionParsing.empty(path: id, product: .claude, modifiedAt: Date(timeIntervalSince1970: t))
            s.isActive = active; s.isAlive = alive
            return s
        }
        let working = make("w", active: true,  alive: true,  at: 100) // mid-turn, process up
        let idle    = make("a", active: false, alive: true,  at: 300) // idle, terminal still open
        let exited  = make("x", active: true,  alive: false, at: 400) // exited: stale-active, process gone
        let closed  = make("c", active: false, alive: false, at: 500) // idle + terminal closed

        let out = SessionEngine.publishable([exited, closed, idle, working])
        XCTAssertEqual(out.map(\.id), ["w", "a"],
                       "a Claude row shows only while its process is alive; exited rows drop even if newest")
    }

    func testPublishableCodexFallsBackToWorking() {
        func make(_ id: String, active: Bool) -> AgentSession {
            var s = SessionParsing.empty(path: id, product: .codex, modifiedAt: Date(timeIntervalSince1970: 1))
            s.isActive = active
            return s
        }
        let out = SessionEngine.publishable([make("on", active: true), make("off", active: false)])
        XCTAssertEqual(out.map(\.id), ["on"], "Codex has no per-session liveness → show while working")
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

    func testClaudeParsesModelTodosAndActivity() {
        var s = SessionParsing.empty(path: "/tmp/proj/s.jsonl", product: .claude, modifiedAt: .distantPast)
        SessionParsing.apply(Data("""
        {"type":"assistant","timestamp":"2026-07-07T10:00:00.000Z","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"wire it up","status":"in_progress"},{"content":"ship","status":"pending"}]}}]}}
        """.utf8), product: .claude, to: &s)

        XCTAssertEqual(s.model, "claude-opus-4-8")
        XCTAssertEqual(s.todos.map(\.status), ["in_progress", "pending"])
        XCTAssertEqual(s.todos.first?.text, "wire it up")
        XCTAssertEqual(s.activity.last?.text, "Running TodoWrite")
    }

    func testActivityFeedEnrichesToolCallsWithTargets() {
        var s = SessionParsing.empty(path: "/tmp/proj/s.jsonl", product: .claude, modifiedAt: .distantPast)
        SessionParsing.apply(Data(#"{"type":"assistant","timestamp":"2026-07-07T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}"#.utf8), product: .claude, to: &s)
        SessionParsing.apply(Data(#"{"type":"assistant","timestamp":"2026-07-07T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/Models.swift"}}]}}"#.utf8), product: .claude, to: &s)

        XCTAssertEqual(s.detail, "Running Read · Models.swift")
        XCTAssertEqual(s.activity.map(\.text), ["Running Bash · git status", "Running Read · Models.swift"])
    }

    func testPublishableKeepsPinnedEvenWhenDead() {
        func make(_ id: String) -> AgentSession {
            var s = SessionParsing.empty(path: id, product: .claude, modifiedAt: .distantPast)
            s.isActive = false; s.isAlive = false
            return s
        }
        let out = SessionEngine.publishable([make("p"), make("gone")], pinned: ["p"])
        XCTAssertEqual(out.map(\.id), ["p"], "a pinned session stays listed even when dead; an unpinned dead one drops")
    }
}
