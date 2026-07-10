import XCTest
import SwiftUI
@testable import agentNotch

// The widget expands from mouse crossings on a mostly transparent panel, so the
// HoverView must classify events by pointer location: tracking areas are torn down
// and rebuilt on every state change, and events for stale or foreign areas (the
// tooltip manager's, for one) must never reach the expand path.
@MainActor
final class HoverViewTests: XCTestCase {
    private var window: NSWindow!
    private var hover: HoverView!
    private var entered = 0
    private var exited = 0
    private var gripEntered = 0
    private var proximityChanges: [Bool] = []

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 584, height: 744),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        hover = HoverView(frame: NSRect(x: 0, y: 0, width: 584, height: 744))
        window.contentView = hover
        entered = 0; exited = 0; gripEntered = 0; proximityChanges = []
        hover.onEnter = { [weak self] in self?.entered += 1 }
        hover.onExit = { [weak self] in self?.exited += 1 }
        hover.onGripEnter = { [weak self] in self?.gripEntered += 1 }
        hover.onGripProximity = { [weak self] near in self?.proximityChanges.append(near) }
        // Right-edge collapsed rail and its grip, as computed by WidgetGeometry.
        hover.activeRect = CGRect(x: 528, y: 262, width: 56, height: 220)
        hover.dragRect = CGRect(x: 504, y: 348, width: 24, height: 48)
        hover.proximityRect = hover.dragRect.insetBy(dx: -28, dy: -28)
    }

    override func tearDown() {
        window.contentView = nil
        window = nil
        hover = nil
        super.tearDown()
    }

    private func crossing(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, trackingNumber: 0,
                               userData: nil)!
    }

    func testEnterInsideWidgetExpandsAndInsideGripDoesNot() {
        hover.mouseEntered(with: crossing(.mouseEntered, at: NSPoint(x: 550, y: 300)))
        XCTAssertEqual(entered, 1)
        XCTAssertEqual(gripEntered, 0)

        hover.mouseEntered(with: crossing(.mouseEntered, at: NSPoint(x: 510, y: 370)))
        XCTAssertEqual(entered, 1)
        XCTAssertEqual(gripEntered, 1)
    }

    func testEnterOutsideBothRectsIsIgnored() {
        // A stale event for a torn-down (previously expanded) tracking area lands
        // outside the current rects and must not reopen the widget.
        for point in [NSPoint(x: 100, y: 370), NSPoint(x: 527, y: 100),
                      NSPoint(x: 550, y: 250), NSPoint(x: 503, y: 370)] {
            hover.mouseEntered(with: crossing(.mouseEntered, at: point))
        }
        XCTAssertEqual(entered, 0)
        XCTAssertEqual(gripEntered, 0)
    }

    func testExitBetweenShapeAndGripDoesNotCollapse() {
        hover.mouseExited(with: crossing(.mouseExited, at: NSPoint(x: 510, y: 370)))
        hover.mouseExited(with: crossing(.mouseExited, at: NSPoint(x: 550, y: 300)))
        XCTAssertEqual(exited, 0)

        hover.mouseExited(with: crossing(.mouseExited, at: NSPoint(x: 400, y: 370)))
        XCTAssertEqual(exited, 1)
    }

    func testTrackingAreasCoverExactlyTheShapeGripAndProximityZone() {
        let tracked = hover.activeRect.union(hover.dragRect).union(hover.proximityRect)
        let ours = hover.trackingAreas.filter { $0.owner === hover }
        let union = ours.reduce(CGRect.null) { $0.union($1.rect) }
        XCTAssertEqual(union, tracked)
        for area in ours {
            XCTAssertTrue(tracked.contains(area.rect))
        }
    }

    // The handle stays hidden until the pointer nears the grip zone — including
    // approaches from outside the widget — and hides again once it moves away.
    func testProximityZoneShowsAndHidesGrip() {
        // Near the grip but outside both the widget shape and the grip itself.
        hover.mouseEntered(with: crossing(.mouseEntered, at: NSPoint(x: 490, y: 330)))
        XCTAssertEqual(proximityChanges, [true])
        XCTAssertEqual(entered, 0)
        XCTAssertEqual(gripEntered, 0)

        // Continuing into the grip keeps it shown; no hide in between.
        hover.mouseEntered(with: crossing(.mouseEntered, at: NSPoint(x: 510, y: 370)))
        XCTAssertEqual(proximityChanges, [true, true])

        // Leaving the zone entirely hides it.
        hover.mouseExited(with: crossing(.mouseExited, at: NSPoint(x: 400, y: 370)))
        XCTAssertEqual(proximityChanges, [true, true, false])
    }

    func testEnteringWidgetAwayFromGripDoesNotShowGrip() {
        hover.mouseEntered(with: crossing(.mouseEntered, at: NSPoint(x: 550, y: 300)))
        XCTAssertEqual(entered, 1)
        XCTAssertEqual(proximityChanges, [])
    }

    func testExitIntoWidgetInteriorHidesGripWithoutCollapsing() {
        hover.mouseEntered(with: crossing(.mouseEntered, at: NSPoint(x: 510, y: 370)))
        // From the grip into the shape, past the proximity zone.
        hover.mouseExited(with: crossing(.mouseExited, at: NSPoint(x: 570, y: 300)))
        XCTAssertEqual(proximityChanges, [true, false])
        XCTAssertEqual(exited, 0)
    }

    func testRebuildingTrackingAreasPreservesForeignAreas() {
        let foreign = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                     options: [.mouseEnteredAndExited, .activeAlways],
                                     owner: NSObject())
        hover.addTrackingArea(foreign)
        hover.activeRect = CGRect(x: 24, y: 182, width: 560, height: 380)
        XCTAssertTrue(hover.trackingAreas.contains(foreign),
                      "Rebuild must not strip tracking areas added by AppKit machinery")
    }
}

// The AppKit tracking rects and the SwiftUI-rendered widget are computed
// independently; render offscreen and assert the drawn pixels stay inside the
// rects the panel tracks (otherwise hover/drag react where nothing is visible).
@MainActor
final class WidgetRenderAlignmentTests: XCTestCase {
    func testRenderedWidgetStaysInsideTrackedRects() throws {
        for (edge, expanded) in [(WidgetEdge.top, false), (.left, false),
                                 (.right, false), (.right, true)] {
            let store = UsageStore()
            store.accounts = [
                AccountUsage(id: "claude:test", product: .claude, label: "claude",
                             windows: [LimitWindow(name: "5H", percent: 72, resetsAt: nil),
                                       LimitWindow(name: "7D", percent: 41, resetsAt: nil)]),
            ]
            let ui = NotchState()
            ui.edge = edge
            ui.expanded = expanded
            let metrics = NotchMetrics(notchWidth: 160,
                                       topCollapsed: CGSize(width: 420, height: 38),
                                       sideCollapsed: WidgetGeometry.sideCollapsedSize,
                                       expanded: CGSize(width: 560, height: 380),
                                       expandedDetail: CGSize(width: 560, height: 720))
            let panelSize = WidgetGeometry.panelSize(maximumShapeSize: metrics.maximumShapeSize)
            let renderer = ImageRenderer(content: ZStack {
                Color(red: 0, green: 0.5, blue: 0)
                NotchRootView(store: store, ui: ui, m: metrics)
            }
            .frame(width: panelSize.width, height: panelSize.height))
            renderer.scale = 1
            let img = try XCTUnwrap(renderer.nsImage)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation)))

            var drawn = CGRect.null
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    let isBackdrop = c.redComponent < 0.15 && c.greenComponent > 0.3
                        && c.blueComponent < 0.15 && c.alphaComponent > 0.9
                    if !isBackdrop {
                        drawn = drawn.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }

            // Compare in top-down pixel coordinates.
            let bounds = CGRect(origin: .zero, size: panelSize)
            let shapeSize = metrics.shapeSize(edge: edge, expanded: expanded, detail: false)
            let appKitShape = WidgetGeometry.activeRect(edge: edge, shapeSize: shapeSize,
                                                        bounds: bounds)
            let shape = CGRect(x: appKitShape.minX, y: bounds.height - appKitShape.maxY,
                               width: appKitShape.width, height: appKitShape.height)
            let grip = WidgetGeometry.swiftUIGripRect(edge: edge, shapeSize: shapeSize,
                                                      bounds: bounds)
            let tracked = shape.union(grip).insetBy(dx: -2, dy: -2)

            XCTAssertFalse(drawn.isNull, "\(edge.rawValue) expanded=\(expanded): nothing rendered")
            XCTAssertTrue(tracked.contains(drawn),
                          "\(edge.rawValue) expanded=\(expanded): drew \(drawn) outside tracked \(tracked)")
            XCTAssertTrue(drawn.contains(shape.insetBy(dx: 10, dy: 10)),
                          "\(edge.rawValue) expanded=\(expanded): shape \(shape) not filled by \(drawn)")
        }
    }
}
