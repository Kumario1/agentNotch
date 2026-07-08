import XCTest
@testable import agentNotch

final class HookInstallerTests: XCTestCase {
    private var tmp: String!

    override func setUp() {
        super.setUp()
        tmp = NSTemporaryDirectory() + "agentnotch-hooktest-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    private func write(_ obj: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        try! data.write(to: URL(fileURLWithPath: tmp))
    }

    private func read(_ event: String = "PreToolUse") -> [[String: Any]] {
        let data = FileManager.default.contents(atPath: tmp)!
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        return hooks[event] as? [[String: Any]] ?? []
    }

    private let isOurs: ([String: Any]) -> Bool = { entry in
        if (entry["command"] as? String ?? "").hasSuffix("agentnotch-hook") { return true }
        let nested = entry["hooks"] as? [[String: Any]] ?? []
        return nested.contains { ($0["command"] as? String ?? "").hasSuffix("agentnotch-hook") }
    }

    // The regression: Claude requires a matcher group with a nested `hooks` array.
    // A flat `{type,command}` entry is silently ignored, so the hook never fires.
    func testInstallClaudeWritesNestedMatcherGroupOnPreToolUse() {
        write(["hooks": ["PreToolUse": []]])
        HookInstaller.installClaude(settingsPath: tmp)

        let entries = read()
        XCTAssertEqual(entries.count, 1)
        let group = entries[0]
        XCTAssertNotNil(group["matcher"], "matcher group must carry a matcher")
        let handlers = group["hooks"] as? [[String: Any]]
        XCTAssertNotNil(handlers, "handlers must be nested under `hooks`")
        XCTAssertTrue((handlers?.first?["command"] as? String ?? "").hasSuffix("agentnotch-hook"))
        XCTAssertNil(group["command"], "must not be a flat command entry")
        XCTAssertTrue(HookInstaller.claudeInstalled(settingsPath: tmp))
    }

    // Installing must migrate a legacy PermissionRequest registration (which couldn't
    // carry a model-visible deny reason) to PreToolUse, preserving unrelated hooks.
    func testInstallClaudeMigratesLegacyPermissionRequestEntry() {
        write(["hooks": ["PermissionRequest": [
            ["matcher": "*", "hooks": [["type": "command", "command": "/old/path/agentnotch-hook", "hookName": "agentnotch-approval"]]],
            ["matcher": "Bash", "hooks": [["type": "command", "command": "/other/tool.sh"]]],
        ]]])

        HookInstaller.installClaude(settingsPath: tmp)

        XCTAssertEqual(read("PreToolUse").filter(isOurs).count, 1, "exactly one of our entries, on PreToolUse")
        XCTAssertTrue(read("PermissionRequest").filter(isOurs).isEmpty, "legacy PermissionRequest entry removed")

        let others = read("PermissionRequest").filter { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/other/tool.sh" }
        XCTAssertEqual(others.count, 1, "unrelated PermissionRequest hooks are preserved")
    }

    func testUninstallClaudeRemovesOursKeepsOthers() {
        HookInstaller.installClaude(settingsPath: tmp) // writes into a fresh file
        // add an unrelated hook alongside ours
        var data = try! JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: tmp)!) as! [String: Any]
        var hooks = data["hooks"] as! [String: Any]
        var entries = hooks["PreToolUse"] as! [[String: Any]]
        entries.append(["matcher": "Bash", "hooks": [["type": "command", "command": "/other/tool.sh"]]])
        hooks["PreToolUse"] = entries
        data["hooks"] = hooks
        try! JSONSerialization.data(withJSONObject: data).write(to: URL(fileURLWithPath: tmp))

        HookInstaller.uninstallClaude(settingsPath: tmp)
        XCTAssertFalse(HookInstaller.claudeInstalled(settingsPath: tmp))
        let entries2 = read()
        XCTAssertEqual(entries2.count, 1)
        XCTAssertEqual((entries2[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String, "/other/tool.sh")
    }
}
