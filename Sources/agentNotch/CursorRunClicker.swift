import AppKit
import ApplicationServices

// Cursor ignores the hook's `permission: allow` for commands it decided to gate itself:
// the hook returns, and Cursor still shows its Skip / Always Run / Run card. The only
// way to complete a notch approval for that pending command is to press the Run button
// for the user. Best-effort by design: needs the Accessibility permission, and quietly
// gives up when no card appears (Cursor honored the allow, or the user clicked Run).
enum CursorRunClicker {
    static func clickPendingRun(timeout: TimeInterval = 8) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard ensureTrusted() else { return }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if clickOnce() { return }
                usleep(400_000)
            }
        }
    }

    /// Triggers the system Accessibility prompt on first use.
    static func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        return false
    }

    private static func clickOnce() -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "Cursor" }
        for app in apps {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            // Electron apps only build their AX tree once assistive access is requested.
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let run = findApprovalRunButton(root) {
                return AXUIElementPerformAction(run, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    // A Run button only counts as the approval card's when Skip / Always Run peers exist,
    // so we never press an unrelated "Run" (editor codelens, task runner, etc.).
    private static func findApprovalRunButton(_ root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        var runs: [AXUIElement] = []
        var sawApprovalPeers = false
        while !queue.isEmpty, visited < 8000 {
            let el = queue.removeFirst()
            visited += 1
            if role(el) == kAXButtonRole as String {
                switch label(el) {
                case "Run": runs.append(el)
                case "Skip", "Always Run", "Always Allow": sawApprovalPeers = true
                default: break
                }
            }
            queue.append(contentsOf: children(el))
        }
        guard sawApprovalPeers else { return nil }
        for run in runs where hasApprovalSibling(run) { return run }
        return runs.first
    }

    private static func hasApprovalSibling(_ el: AXUIElement) -> Bool {
        guard let parent = parent(el) else { return false }
        return children(parent).contains {
            let l = label($0)
            return l == "Skip" || l == "Always Run"
        }
    }

    // MARK: - AX helpers

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    private static func role(_ el: AXUIElement) -> String? {
        attr(el, kAXRoleAttribute as String) as? String
    }

    private static func label(_ el: AXUIElement) -> String? {
        for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
            if let s = attr(el, key) as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func parent(_ el: AXUIElement) -> AXUIElement? {
        guard let ref = attr(el, kAXParentAttribute as String),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }
}
