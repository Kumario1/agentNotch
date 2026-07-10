import AppKit
import SwiftUI

// The panel owns one maximum-size transparent hit area while SwiftUI renders the
// current widget state inside it.
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
    var onGripEnter: (() -> Void)?
    var onGripProximity: ((Bool) -> Void)?
    var activeRect: CGRect = .zero { didSet { if activeRect != oldValue { updateTrackingAreas() } } }
    var proximityRect: CGRect = .zero {
        didSet { if proximityRect != oldValue { updateTrackingAreas() } }
    }
    var dragRect: CGRect = .zero {
        didSet {
            guard dragRect != oldValue else { return }
            // The tooltip lives outside updateTrackingAreas: re-adding it there made
            // NSToolTipManager churn its own tracking area on every rebuild pass.
            if let gripToolTip { removeToolTip(gripToolTip); self.gripToolTip = nil }
            if !dragRect.isEmpty {
                gripToolTip = addToolTip(dragRect, owner: self, userData: nil)
            }
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }
    var dragging = false {
        didSet { if dragging != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    private var expandTrackingAreas: [NSTrackingArea] = []
    private var dragTrackingArea: NSTrackingArea?
    private var proximityTrackingArea: NSTrackingArea?
    private var gripToolTip: NSView.ToolTipTag?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove only the areas this view added; the view also hosts foreign areas
        // (the tooltip manager's, for one) that must survive a rebuild.
        expandTrackingAreas.forEach(removeTrackingArea)
        expandTrackingAreas = []
        if let dragTrackingArea { removeTrackingArea(dragTrackingArea) }
        dragTrackingArea = nil
        if let proximityTrackingArea { removeTrackingArea(proximityTrackingArea) }
        proximityTrackingArea = nil

        if !proximityRect.isNull, !proximityRect.isEmpty {
            proximityTrackingArea = NSTrackingArea(rect: proximityRect,
                                                   options: [.mouseEnteredAndExited,
                                                             .activeAlways],
                                                   owner: self)
            addTrackingArea(proximityTrackingArea!)
        }

        if !dragRect.isNull, !dragRect.isEmpty {
            dragTrackingArea = NSTrackingArea(rect: dragRect,
                                              options: [.mouseEnteredAndExited, .cursorUpdate,
                                                        .activeAlways],
                                              owner: self)
            addTrackingArea(dragTrackingArea!)
        }

        guard activeRect != .zero else { return }
        let overlap = activeRect.intersection(dragRect)
        for rect in subtract(activeRect, by: overlap) where !rect.isEmpty {
            let area = NSTrackingArea(rect: rect,
                                      options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: self)
            expandTrackingAreas.append(area)
            addTrackingArea(area)
        }
    }

    // Classify crossings by where the pointer is now, not by tracking-area identity:
    // areas are rebuilt whenever the widget changes state, so events can arrive for
    // instances that no longer exist (and the tooltip machinery delivers events for
    // areas this view never created). Matching on identity routed those strays into
    // the expand path, popping the widget open from outside the visible shape.
    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if proximityRect.contains(point) { onGripProximity?(true) }
        if dragRect.contains(point) {
            (dragging ? NSCursor.closedHand : NSCursor.openHand).set()
            onGripEnter?()
        } else if activeRect.contains(point) {
            onEnter?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !proximityRect.contains(point) { onGripProximity?(false) }
        // Moving between the shape and the grip is not an exit.
        guard !activeRect.contains(point), !dragRect.contains(point) else { return }
        if !dragging { NSCursor.arrow.set() }
        onExit?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard dragRect != .zero else { return }
        addCursorRect(dragRect, cursor: dragging ? .closedHand : .openHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        if dragRect.contains(convert(event.locationInWindow, from: nil)) {
            (dragging ? NSCursor.closedHand : NSCursor.openHand).set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "Drag to move widget"
    }

    private func subtract(_ rect: CGRect, by cut: CGRect) -> [CGRect] {
        guard !cut.isNull, !cut.isEmpty else { return [rect] }

        var regions: [CGRect] = []
        if cut.minY > rect.minY {
            regions.append(CGRect(x: rect.minX, y: rect.minY,
                                  width: rect.width, height: cut.minY - rect.minY))
        }
        if cut.maxY < rect.maxY {
            regions.append(CGRect(x: rect.minX, y: cut.maxY,
                                  width: rect.width, height: rect.maxY - cut.maxY))
        }
        if cut.minX > rect.minX {
            regions.append(CGRect(x: rect.minX, y: cut.minY,
                                  width: cut.minX - rect.minX, height: cut.height))
        }
        if cut.maxX < rect.maxX {
            regions.append(CGRect(x: cut.maxX, y: cut.minY,
                                  width: rect.maxX - cut.maxX, height: cut.height))
        }
        return regions
    }
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

    private var metrics = NotchMetrics(notchWidth: 0, topCollapsed: .zero,
                                       sideCollapsed: WidgetGeometry.sideCollapsedSize,
                                       expanded: .zero, expandedDetail: .zero)
    private var panelRect: CGRect = .zero
    private var collapseWork: DispatchWorkItem?
    private var placement: WidgetPlacement
    private var placementScreen: NSScreen?
    private var isDragging = false

    init(settings: SettingsController, claudeDirs: [URL], placement: WidgetPlacement = .init()) {
        self.settings = settings
        self.accountSwitcher = ClaudeAccountSwitcher(dirs: claudeDirs)
        self.placement = placement
        ui.edge = placement.edge
        self.approvalServer = ApprovalServer(store: store)
        computeRects()
        rebuildHost()
        hover.onEnter = { [weak self] in self?.handleHoverEnter() }
        hover.onExit = { [weak self] in self?.scheduleCollapse() }
        hover.onGripEnter = { [weak self] in self?.cancelCollapse() }
        hover.onGripProximity = { [weak self] near in self?.ui.gripVisible = near }
        panel.contentView = hover
        refreshActiveClaudeAccount()
    }

    func start() {
        approvalServer.start()
        observeApprovals()
        observeSelection()
    }

    // Resize the hover area the moment a session is opened or closed.
    private func observeSelection() {
        withObservationTracking {
            _ = ui.selectedSessionID
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateTracking()
                self?.observeSelection()
            }
        }
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
            onGripDragStarted: { [weak self] in
                self?.beginDrag(at: NSEvent.mouseLocation)
            },
            onGripDragChanged: { [weak self] in
                self?.drag(to: NSEvent.mouseLocation)
            },
            onGripDragEnded: { [weak self] in
                self?.endDrag(at: NSEvent.mouseLocation)
            },
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
        let screen = layoutScreen()
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

        let topCollapsed = CGSize(width: notch.width + 260, height: max(notch.height, 24) + 10)
        // The expanded view shows one account card + a scrolling session list, so the
        // height is fixed — not scaled by account count. A pending approval needs a bit more.
        let hasApproval = !store.pendingApprovals.isEmpty
        let expanded = CGSize(width: max(540, topCollapsed.width + 140),
                              height: hasApproval ? 440 : 380)
        // Opening one session grows the notch taller to show its full detail.
        let expandedDetail = CGSize(width: expanded.width, height: 720)
        metrics = NotchMetrics(notchWidth: notch.width, topCollapsed: topCollapsed,
                               sideCollapsed: WidgetGeometry.sideCollapsedSize,
                               expanded: expanded, expandedDetail: expandedDetail)
        panelRect = WidgetGeometry.panelRect(
            edge: placement.edge,
            position: placement.position,
            size: WidgetGeometry.panelSize(maximumShapeSize: metrics.maximumShapeSize),
            screenFrame: f)
    }

    private func layoutScreen() -> NSScreen {
        if let placementScreen,
           NSScreen.screens.contains(where: { $0 === placementScreen }) {
            return placementScreen
        }

        if panel.frame != .zero {
            let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                placementScreen = screen
                return screen
            }
        }

        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        placementScreen = screen
        return screen
    }

    private func screen(at point: NSPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? layoutScreen()
    }

    // Hover area tracks the visible shape so the transparent space below it isn't a
    // dead zone. Grows with the detail view; re-run when a session is opened/closed.
    private func updateTracking() {
        let size = metrics.shapeSize(edge: ui.edge, expanded: ui.expanded,
                                     detail: ui.selectedSessionID != nil)
        let activeRect = WidgetGeometry.activeRect(edge: ui.edge, shapeSize: size,
                                                   bounds: hover.bounds)
        hover.activeRect = activeRect
        hover.dragRect = WidgetGeometry.gripRect(edge: ui.edge, shapeRect: activeRect)
        hover.proximityRect = WidgetGeometry.gripProximityRect(edge: ui.edge,
                                                               shapeRect: activeRect)
        // Rects just moved under a stationary pointer; enter/exit events won't fire
        // for that, so re-derive visibility from where the pointer is now.
        ui.gripVisible = hover.proximityRect.contains(pointerInHoverView())
    }

    // MARK: - Hover expand / collapse

    private func handleHoverEnter() {
        guard !isDragging else { return }
        expand()
    }

    private func expand() {
        collapseWork?.cancel(); collapseWork = nil
        guard !isDragging, !ui.expanded else { return }
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
        guard !isDragging else { return }
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsOverWidgetOrGrip() else { return }
            self.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    private func pointerInHoverView() -> NSPoint {
        let pointInWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        return hover.convert(pointInWindow, from: nil)
    }

    private func pointerIsOverWidgetOrGrip() -> Bool {
        let point = pointerInHoverView()
        return hover.activeRect.contains(point) || hover.dragRect.contains(point)
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

    // MARK: - Edge dragging

    private func beginDrag(at point: NSPoint) {
        cancelCollapse()
        isDragging = true
        ui.dragging = true
        hover.dragging = true
        NSCursor.closedHand.set()

        // Moving a compact shell is easier to track than a 540-point popup. This
        // only happens after the pointer has crossed the panel's 5-point threshold.
        if ui.expanded {
            collapse()
        } else {
            updateTracking()
        }
        drag(to: point)
    }

    // The widget never floats free while dragging: it stays pinned to an edge and
    // slides along it, hopping to another edge when the pointer nears one. The
    // resting layout math places it, so drop and drag agree exactly.
    private func drag(to point: NSPoint) {
        guard isDragging else { return }
        let screenFrame = screen(at: point).frame

        if let preview = WidgetGeometry.dockingPreview(
            for: point, in: screenFrame, currentEdge: ui.edge),
           preview != ui.edge {
            ui.edge = preview
            updateTracking()
        }

        let position = WidgetGeometry.normalizedPosition(for: point, edge: ui.edge,
                                                         screenFrame: screenFrame)
        panel.setFrameOrigin(WidgetGeometry.panelRect(edge: ui.edge, position: position,
                                                      size: panel.frame.size,
                                                      screenFrame: screenFrame).origin)
    }

    private func endDrag(at point: NSPoint) {
        guard isDragging else { return }

        let screen = screen(at: point)
        let f = screen.frame
        let edge = WidgetGeometry.dockingPreview(for: point, in: f, currentEdge: ui.edge)
            ?? WidgetGeometry.nearestEdge(to: point, in: f)
        let position = WidgetGeometry.normalizedPosition(for: point, edge: edge, screenFrame: f)

        placement = WidgetPlacement(edge: edge, position: position)
        placement.save()
        placementScreen = screen
        ui.edge = edge
        ui.dragging = false
        isDragging = false
        hover.dragging = false
        NSCursor.openHand.set()
        computeRects()
        rebuildHost()
        panel.setFrame(panelRect, display: true)
        updateTracking()
    }
}
