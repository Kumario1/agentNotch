import AppKit
import SwiftUI

// The one panel, never recreated or resized — it always occupies the expanded rect,
// and SwiftUI animates the visible notch shape inside it.
final class NotchPanel: NSPanel {
    var keyWhilePending = false

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { keyWhilePending }
    override var canBecomeMain: Bool { false }
}

// Hover tracking over an explicit sub-rect (just the visible black shape),
// since the panel itself is mostly transparent.
final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var activeRect: CGRect = .zero { didSet { if activeRect != oldValue { updateTrackingAreas() } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard activeRect != .zero else { return }
        addTrackingArea(NSTrackingArea(rect: activeRect,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

final class NotchController {
    let store = UsageStore()
    var onExpand: (() -> Void)?
    private let ui = NotchState()
    private let panel = NotchPanel()
    private let hover = HoverView()
    private var host: NSHostingView<NotchRootView>!
    private var keyMonitor: Any?
    private let approvalServer: ApprovalServer
    private let settings: SettingsController
    private let accountSwitcher: ClaudeAccountSwitcher

    private var metrics = NotchMetrics(notchWidth: 0, collapsed: .zero, expanded: .zero)
    private var panelRect: CGRect = .zero
    private var collapseWork: DispatchWorkItem?

    init(settings: SettingsController, claudeDirs: [URL]) {
        self.settings = settings
        self.accountSwitcher = ClaudeAccountSwitcher(dirs: claudeDirs)
        self.approvalServer = ApprovalServer(store: store)
        computeRects()
        rebuildHost()
        hover.onEnter = { [weak self] in self?.expand() }
        hover.onExit = { [weak self] in self?.scheduleCollapse() }
        panel.contentView = hover
        refreshActiveClaudeAccount()
    }

    func start() {
        approvalServer.start()
        observeApprovals()
    }

    func show() {
        panel.setFrame(panelRect, display: true)
        panel.orderFrontRegardless()
        updateTracking()
    }

    func reposition() {
        computeRects()
        rebuildHost()
        panel.setFrame(panelRect, display: true)
        updateTracking()
    }

    private func rebuildHost() {
        host?.removeFromSuperview()
        host = NSHostingView(rootView: NotchRootView(
            store: store,
            ui: ui,
            m: metrics,
            onOpenSettings: { [weak self] in self?.settings.show() },
            onApprovalDecision: { [weak self] id, decision, reason in
                self?.approvalServer.decide(id, decision: decision, reason: reason)
            },
            onSwitchClaudeAccount: { [weak self] accountID in
                self?.switchClaudeAccount(to: accountID)
            }))
        host.autoresizingMask = [.width, .height]
        host.frame = hover.bounds
        hover.addSubview(host)
    }

    private func refreshActiveClaudeAccount() {
        accountSwitcher.refreshActiveID { [weak self] id in
            DispatchQueue.main.async {
                self?.store.activeClaudeAccountID = id
            }
        }
    }

    private func switchClaudeAccount(to accountID: String) {
        accountSwitcher.activate(accountID: accountID) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, case .success = result else { return }
                self.store.activeClaudeAccountID = accountID
                self.ui.selectedAccountID = accountID
            }
        }
    }

    private func observeApprovals() {
        withObservationTracking {
            _ = store.pendingApprovals.count
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.handleApprovalChange()
                self?.observeApprovals()
            }
        }
    }

    private func handleApprovalChange() {
        let pending = !store.pendingApprovals.isEmpty
        panel.keyWhilePending = pending
        if pending {
            // Don't steal focus or force-expand — just let the resting notch bounce
            // for attention. The user opens it (hover) to decide; keyboard shortcuts
            // come online only once it's actually open.
            panel.orderFrontRegardless()
            if ui.expanded {
                panel.makeKeyAndOrderFront(nil)
                installKeyMonitor()
            }
        } else {
            removeKeyMonitor()
            panel.resignKey()
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let req = self.store.currentApproval else { return event }
            // Typing a deny reason: never intercept — let the text field receive every key.
            if self.ui.collectingFeedback { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "a", flags.contains(.option) {
                self.approvalServer.decide(req.id, decision: .always); return nil
            }
            if key == "a", flags.contains(.command) {
                self.approvalServer.decide(req.id, decision: .allow); return nil
            }
            if key == "n", flags.contains(.command) {
                self.approvalServer.decide(req.id, decision: .deny); return nil
            }
            return event   // plain keys (incl. a bare "a") pass through
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - Geometry

    private func computeRects() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        let notch: CGRect
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let width = r.minX - l.maxX
            notch = CGRect(x: f.minX + l.maxX, y: f.maxY - screen.safeAreaInsets.top,
                           width: width, height: screen.safeAreaInsets.top)
        } else {
            notch = CGRect(x: f.midX - 100, y: f.maxY - 32, width: 200, height: 32)
        }

        let collapsed = CGSize(width: notch.width + 260, height: max(notch.height, 24) + 10)
        // The expanded view shows one account card + a scrolling session list, so the
        // height is fixed — not scaled by account count. A pending approval needs a bit more.
        let hasApproval = !store.pendingApprovals.isEmpty
        let expanded = CGSize(width: max(540, collapsed.width + 140), height: hasApproval ? 440 : 380)
        metrics = NotchMetrics(notchWidth: notch.width, collapsed: collapsed, expanded: expanded)
        panelRect = CGRect(x: notch.midX - expanded.width / 2, y: notch.maxY - expanded.height,
                           width: expanded.width, height: expanded.height)
    }

    private func updateTracking() {
        let b = hover.bounds
        hover.activeRect = ui.expanded ? b : CGRect(
            x: (b.width - metrics.collapsed.width) / 2,
            y: b.height - metrics.collapsed.height,
            width: metrics.collapsed.width, height: metrics.collapsed.height)
    }

    // MARK: - Hover expand / collapse

    private func expand() {
        collapseWork?.cancel(); collapseWork = nil
        guard !ui.expanded else { return }
        ui.expanded = true
        updateTracking()
        onExpand?()
        // Opening while an approval is pending brings keyboard shortcuts online.
        if panel.keyWhilePending {
            panel.makeKeyAndOrderFront(nil)
            installKeyMonitor()
        }
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func collapse() {
        guard ui.expanded else { return }
        ui.selectedSessionID = nil
        ui.expanded = false
        updateTracking()
        // Back to the resting notch: hand focus back and stop listening for shortcuts.
        // If an approval is still pending, SwiftUI resumes the attention bounce.
        removeKeyMonitor()
        panel.resignKey()
    }
}
