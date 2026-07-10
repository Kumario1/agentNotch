import XCTest
import SwiftUI
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

    func testConfigLaunchAtLoginRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.json").path

        var c = AppConfig.parse(nil)
        c.launchAtLogin = true
        c.save(to: path)
        let loaded = AppConfig.load(configPath: path)
        XCTAssertTrue(loaded.launchAtLogin)

        c.launchAtLogin = false
        c.save(to: path)
        XCTAssertFalse(AppConfig.parse(FileManager.default.contents(atPath: path)).launchAtLogin)
    }

    func testWidgetPlacementRoundTripAndClamping() {
        let suiteName = "agentnotch-placement-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        WidgetPlacement(edge: .right, position: 2).save(to: defaults)
        XCTAssertEqual(WidgetPlacement.load(from: defaults), WidgetPlacement(edge: .right, position: 1))

        defaults.set("unknown", forKey: "widget.edge")
        defaults.set(-1, forKey: "widget.position")
        XCTAssertEqual(WidgetPlacement.load(from: defaults), WidgetPlacement(edge: .top, position: 0))
    }

    func testWidgetGeometryUsesContentFitSideRailAndGripEnvelope() {
        XCTAssertEqual(WidgetGeometry.sideCollapsedSize, CGSize(width: 56, height: 220))
        XCTAssertEqual(
            WidgetGeometry.panelSize(maximumShapeSize: CGSize(width: 540, height: 720)),
            CGSize(width: 564, height: 744))
    }

    func testWidgetGeometryPanelRectAttachesAndClampsToEveryEdge() {
        let screen = CGRect(x: 100, y: 50, width: 1_440, height: 900)
        let size = CGSize(width: 564, height: 744)

        let top = WidgetGeometry.panelRect(edge: .top, position: 0.5,
                                           size: size, screenFrame: screen)
        XCTAssertEqual(top.midX, screen.midX)
        XCTAssertEqual(top.maxY, screen.maxY)

        let left = WidgetGeometry.panelRect(edge: .left, position: -1,
                                            size: size, screenFrame: screen)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(left.minY, screen.minY)

        let right = WidgetGeometry.panelRect(edge: .right, position: 2,
                                             size: size, screenFrame: screen)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertEqual(right.maxY, screen.maxY)
    }

    func testWidgetGeometryPlacesGripBeyondEachFreeEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 564, height: 744)

        let topShape = WidgetGeometry.activeRect(edge: .top,
                                                 shapeSize: CGSize(width: 460, height: 42),
                                                 bounds: bounds)
        let topGrip = WidgetGeometry.gripRect(edge: .top, shapeRect: topShape)
        XCTAssertEqual(topGrip.maxY, topShape.minY)
        XCTAssertEqual(topGrip.midX, topShape.midX)
        XCTAssertTrue(bounds.contains(topGrip))

        let leftShape = WidgetGeometry.activeRect(edge: .left,
                                                  shapeSize: WidgetGeometry.sideCollapsedSize,
                                                  bounds: bounds)
        let leftGrip = WidgetGeometry.gripRect(edge: .left, shapeRect: leftShape)
        XCTAssertEqual(leftGrip.minX, leftShape.maxX)
        XCTAssertEqual(leftGrip.midY, leftShape.midY)
        XCTAssertTrue(bounds.contains(leftGrip))

        let rightShape = WidgetGeometry.activeRect(edge: .right,
                                                   shapeSize: WidgetGeometry.sideCollapsedSize,
                                                   bounds: bounds)
        let rightGrip = WidgetGeometry.gripRect(edge: .right, shapeRect: rightShape)
        XCTAssertEqual(rightGrip.maxX, rightShape.minX)
        XCTAssertEqual(rightGrip.midY, rightShape.midY)
        XCTAssertTrue(bounds.contains(rightGrip))
    }

    func testWidgetGeometryDockPreviewThresholdAndHysteresis() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        XCTAssertEqual(WidgetGeometry.dockingPreview(
            for: CGPoint(x: 720, y: 820), in: screen, currentEdge: .left), .top)
        XCTAssertEqual(WidgetGeometry.dockingPreview(
            for: CGPoint(x: 80, y: 450), in: screen, currentEdge: .top), .left)
        XCTAssertNil(WidgetGeometry.dockingPreview(
            for: CGPoint(x: 720, y: 450), in: screen, currentEdge: .top))

        // The left edge is only eight points closer, so keep the top preview.
        XCTAssertEqual(WidgetGeometry.dockingPreview(
            for: CGPoint(x: 8, y: 884), in: screen, currentEdge: .top), .top)
        // Once it is more than 24 points closer, switch to the left preview.
        XCTAssertEqual(WidgetGeometry.dockingPreview(
            for: CGPoint(x: 8, y: 840), in: screen, currentEdge: .top), .left)
    }

    func testWidgetGeometryNormalizesDropPosition() {
        let screen = CGRect(x: 100, y: 50, width: 1_000, height: 800)
        XCTAssertEqual(WidgetGeometry.normalizedPosition(
            for: CGPoint(x: 350, y: 700), edge: .top, screenFrame: screen), 0.25)
        XCTAssertEqual(WidgetGeometry.normalizedPosition(
            for: CGPoint(x: 350, y: 250), edge: .left, screenFrame: screen), 0.25)
        XCTAssertEqual(WidgetGeometry.normalizedPosition(
            for: CGPoint(x: -100, y: 2_000), edge: .right, screenFrame: screen), 1)
    }

    @MainActor
    func testWidgetCompactLayoutsRenderForEveryEdge() {
        for edge in [WidgetEdge.top, .left, .right] {
            let store = UsageStore()
            store.accounts = [
                AccountUsage(id: "claude:test", product: .claude, label: "claude",
                             windows: [LimitWindow(name: "5H", percent: 72, resetsAt: nil),
                                       LimitWindow(name: "7D", percent: 41, resetsAt: nil)]),
                AccountUsage(id: "cursor:test", product: .cursor, label: "cursor",
                             windows: [LimitWindow(name: "API", percent: 65, resetsAt: nil),
                                       LimitWindow(name: "AUTO", percent: 88, resetsAt: nil)]),
            ]
            let state = NotchState()
            state.edge = edge
            let metrics = NotchMetrics(notchWidth: 200,
                                       topCollapsed: CGSize(width: 460, height: 42),
                                       sideCollapsed: WidgetGeometry.sideCollapsedSize,
                                       expanded: CGSize(width: 540, height: 380),
                                       expandedDetail: CGSize(width: 540, height: 720))
            let panelSize = WidgetGeometry.panelSize(maximumShapeSize: metrics.maximumShapeSize)
            let renderer = ImageRenderer(content:
                ZStack {
                    Color(red: 0.05, green: 0.28, blue: 0.72)
                    NotchRootView(store: store, ui: state, m: metrics)
                }
                .frame(width: panelSize.width, height: panelSize.height))
            renderer.scale = 2
            XCTAssertNotNil(renderer.nsImage, "Could not render \(edge.rawValue) compact widget")
        }
    }

    func testWidgetGripUsesFivePointDragThreshold() {
        XCTAssertEqual(WidgetGeometry.dragThreshold, 5)
    }

    func testSwiftUIGripGeometryMatchesTopDownPanelCoordinates() {
        let bounds = CGRect(x: 0, y: 0, width: 564, height: 744)
        let top = WidgetGeometry.swiftUIGripRect(
            edge: .top, shapeSize: CGSize(width: 460, height: 42), bounds: bounds)
        XCTAssertEqual(top, CGRect(x: 258, y: 42, width: 48, height: 24))

        let left = WidgetGeometry.swiftUIGripRect(
            edge: .left, shapeSize: WidgetGeometry.sideCollapsedSize, bounds: bounds)
        XCTAssertEqual(left, CGRect(x: 56, y: 348, width: 24, height: 48))

        let right = WidgetGeometry.swiftUIGripRect(
            edge: .right, shapeSize: WidgetGeometry.sideCollapsedSize, bounds: bounds)
        XCTAssertEqual(right, CGRect(x: 484, y: 348, width: 24, height: 48))
    }

    func testLaunchAtLoginInstallHintForDMGAndBareBinary() {
        XCTAssertNotNil(LaunchAtLogin.installHint(bundlePath: "/Volumes/agentNotch/agentNotch.app"))
        XCTAssertNotNil(LaunchAtLogin.installHint(bundlePath: "/private/var/folders/xx/AppTranslocation/abc/agentNotch.app"))
        XCTAssertNotNil(LaunchAtLogin.installHint(bundlePath: "/tmp/.build/release/agentNotch"))
        XCTAssertNil(LaunchAtLogin.installHint(bundlePath: "/Applications/agentNotch.app"))
    }

    // MARK: Account discovery

    func testDiscoverClaudeFindsDefaultAndSiblingAccountDirs() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-discover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        let work = home.appendingPathComponent("claude-work", isDirectory: true)
        let decoy = home.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"a@x.com"}}"#.utf8)
            .write(to: claude.appendingPathComponent(".claude.json"))
        try Data(#"{"claudeAiOauth":{"accessToken":"t"}}"#.utf8)
            .write(to: work.appendingPathComponent(".credentials.json"))
        try Data("hello".utf8).write(to: decoy.appendingPathComponent("readme.txt"))

        let found = AccountDiscovery.claudeDirs(home: home)
        XCTAssertEqual(Set(found.map(\.lastPathComponent)), [".claude", "claude-work"])
    }

    func testDiscoverCodexAndCursorOnlyWhenPresent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-discover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)

        XCTAssertEqual(AccountDiscovery.codexDirs(home: home).map(\.lastPathComponent), [".codex"])
        XCTAssertEqual(AccountDiscovery.cursorDirs(home: home), [])
    }

    func testLoadWithoutConfigFileMergesDiscoveryAndPersists() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-load-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let configPath = home.appendingPathComponent(".agentnotch.json").path
        let work = home.appendingPathComponent("claude-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data(#"{"claudeAiOauth":{"accessToken":"t"}}"#.utf8)
            .write(to: work.appendingPathComponent(".credentials.json"))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cursor", isDirectory: true),
            withIntermediateDirectories: true)

        let c = AppConfig.load(configPath: configPath, home: home)
        XCTAssertTrue(c.claudeDirs.contains { $0.lastPathComponent == "claude-work" })
        XCTAssertEqual(c.codexDirs.map(\.lastPathComponent), [".codex"])
        XCTAssertEqual(c.cursorDirs.map(\.lastPathComponent), [".cursor"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath), "first launch should persist discovery")
    }

    func testLoadWithExistingConfigDoesNotOverwriteDirs() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-load-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let configPath = home.appendingPathComponent(".agentnotch.json").path
        let only = home.appendingPathComponent("only-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: only, withIntermediateDirectories: true)
        let json = Data(#"{"claude":["\#(only.path)"],"codex":[],"cursor":[]}"#.utf8)
        try json.write(to: URL(fileURLWithPath: configPath))
        // Extra discoverable dir that must NOT be auto-added when config already exists.
        let extra = home.appendingPathComponent("claude-extra", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data(#"{"claudeAiOauth":{"accessToken":"t"}}"#.utf8)
            .write(to: extra.appendingPathComponent(".credentials.json"))

        let c = AppConfig.load(configPath: configPath, home: home)
        XCTAssertEqual(c.claudeDirs.map(\.path), [only.path])
        XCTAssertEqual(c.codexDirs, [])
        XCTAssertEqual(c.cursorDirs, [])
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

    // Real payload shape: the dashboard's Auto/API meters are percentages used of the
    // included budget. We surface both as remaining-%, and totalSpend > limit (bonus
    // usage) must NOT collapse them to "0% left".
    func testCursorPeriodUsageSplitsAutoAndApi() {
        let json = Data("""
        {"billingCycleEnd":"1786116841000",
         "planUsage":{"totalSpend":2479,"includedSpend":2000,"limit":2000,
                      "autoPercentUsed":7.066666,"apiPercentUsed":48.022222,"totalPercentUsed":27.544}}
        """.utf8)
        let w = CursorLimits.windows(fromPeriodUsage: json)
        XCTAssertEqual(w.map(\.name), ["API", "AUTO"])
        XCTAssertEqual(w[0].percent, 51.98, accuracy: 0.01, "100 - apiPercentUsed")
        XCTAssertEqual(w[1].percent, 92.93, accuracy: 0.01, "100 - autoPercentUsed")
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1_786_116_841))
    }

    func testCursorPeriodUsageFallsBackToTotalPercentWhenNoSplit() {
        let json = Data(#"{"planUsage":{"totalPercentUsed":40}}"#.utf8)
        let w = CursorLimits.windows(fromPeriodUsage: json)
        XCTAssertEqual(w.map(\.name), ["PLAN"])
        XCTAssertEqual(w[0].percent, 60)
    }

    func testCursorPeriodUsageFallsBackToSpendLimit() {
        let json = Data(#"{"planUsage":{"totalSpend":500,"limit":2000}}"#.utf8)
        let w = CursorLimits.windows(fromPeriodUsage: json)
        XCTAssertEqual(w.map(\.name), ["PLAN"])
        XCTAssertEqual(w[0].percent, 75, "remaining = (limit - totalSpend)/limit")
    }

    func testCursorPeriodUsageEmptyAndClamped() {
        XCTAssertEqual(CursorLimits.windows(fromPeriodUsage: Data("{}".utf8)), [])
        XCTAssertEqual(CursorLimits.windows(fromPeriodUsage: Data("not json".utf8)), [])
        let maxed = Data(#"{"planUsage":{"apiPercentUsed":140}}"#.utf8)
        XCTAssertEqual(CursorLimits.windows(fromPeriodUsage: maxed)[0].percent, 0,
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
