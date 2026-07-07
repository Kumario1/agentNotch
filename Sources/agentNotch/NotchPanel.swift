import AppKit
import SwiftUI

// The one panel, never recreated or resized — it always occupies the expanded rect,
// and SwiftUI animates the visible notch shape inside it. Animating the window frame
// (the old approach) is what made transitions read as a cut between two layouts.
final class NotchPanel: NSPanel {
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
    override var canBecomeKey: Bool { false }
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
    private let ui = NotchState()
    private let panel = NotchPanel()
    private let hover = HoverView()
    private var host: NSHostingView<NotchRootView>!

    private var metrics = NotchMetrics(notchWidth: 0, collapsed: .zero, expanded: .zero)
    private var panelRect: CGRect = .zero
    private var collapseWork: DispatchWorkItem?
    private var accountCount = 1

    func setAccountCount(_ n: Int) {
        guard n != accountCount, n > 0 else { return }
        accountCount = n
        reposition()
    }

    init() {
        computeRects()
        host = NSHostingView(rootView: NotchRootView(store: store, ui: ui, m: metrics))
        host.autoresizingMask = [.width, .height]
        host.frame = hover.bounds
        hover.addSubview(host)
        hover.onEnter = { [weak self] in self?.expand() }
        hover.onExit = { [weak self] in self?.scheduleCollapse() }
        panel.contentView = hover
    }

    func show() {
        panel.setFrame(panelRect, display: true)
        panel.orderFrontRegardless()
        updateTracking()
    }

    func reposition() {
        computeRects()
        host.rootView = NotchRootView(store: store, ui: ui, m: metrics)
        panel.setFrame(panelRect, display: true)
        updateTracking()
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
            // Non-notch screen: fixed 200x32 centered under the top edge.
            notch = CGRect(x: f.midX - 100, y: f.maxY - 32, width: 200, height: 32)
        }

        // Black border extends 130pt into each wing and 10pt below the notch.
        let collapsed = CGSize(width: notch.width + 260, height: max(notch.height, 24) + 10)
        // Height grows with account rows, but session list/detail needs a usable floor.
        let height = max(360, CGFloat(120 + 110 * max(accountCount, 1)))
        let expanded = CGSize(width: max(540, collapsed.width + 140), height: height)
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

    // MARK: - Hover expand / collapse (SwiftUI's .smooth spring does the animating)

    private func expand() {
        collapseWork?.cancel(); collapseWork = nil
        guard !ui.expanded else { return }
        ui.expanded = true
        updateTracking()
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work) // grace debounce
    }

    private func collapse() {
        guard ui.expanded else { return }
        ui.selectedSessionID = nil
        ui.expanded = false
        updateTracking()
    }
}
