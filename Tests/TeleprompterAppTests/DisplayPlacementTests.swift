import XCTest
import AppKit
@testable import TeleprompterApp

final class DisplayPlacementTests: XCTestCase {
    func screen(_ id: UInt32, _ frame: CGRect, band: CGFloat, housing: CGFloat = 0, scale: CGFloat = 2) -> NotchDisplay {
        NotchDisplay(id: id, bounds: frame, visibleBounds: CGRect(x: frame.minX, y: frame.minY + 55, width: frame.width, height: frame.height - 55 - band), cameraHousing: housing, safeTop: housing > 0 ? band : 0, scale: scale)
    }
    func testCompactExternalBarFitsMenuBandAtEveryScreenOriginAndScale() {
        for origin in [CGPoint.zero, CGPoint(x: -1920, y: 0), CGPoint(x: 400, y: 1080), CGPoint(x: 0, y: -1440)] {
            for scale in [1.0, 2.0] {
                for band in [22.0, 24, 28] {
                    let display = screen(1, CGRect(origin: origin, size: CGSize(width: 1920, height: 1080)), band: band, scale: scale)
                    XCTAssertEqual(display.compactFrame.width, 220)
                    XCTAssertEqual((display.layout.leftControl.minX + display.layout.rightControl.maxX) / 2,
                                   display.layout.size.width / 2, "Center the wordmark and chevron on unobstructed screens")
                    XCTAssertEqual(display.compactFrame.maxY, display.bounds.maxY)
                    XCTAssertGreaterThanOrEqual(display.compactFrame.minY, display.visibleBounds.maxY, "Never enter browser tabs")
                    XCTAssertEqual(display.panelFrame.maxY, display.bounds.maxY)
                    XCTAssertEqual(display.layout.housing, 0)
                    for button in [display.layout.leftControl, display.layout.rightControl] {
                        XCTAssertGreaterThanOrEqual(button.minY, 0)
                        XCTAssertLessThanOrEqual(button.maxY, band)
                    }
                }
            }
        }
    }
    func testNotchedDisplayAndAutoHiddenBand() {
        let builtin = screen(1, CGRect(x: 0, y: 0, width: 1512, height: 982), band: 38, housing: 190)
        XCTAssertEqual(builtin.compactFrame.width, 334)
        XCTAssertEqual(builtin.layout.size, CGSize(width: 558, height: 248))
        let external = screen(2, CGRect(x: 0, y: -1080, width: 1920, height: 1080), band: 0)
        XCTAssertFalse(external.showsCompact)
        XCTAssertEqual(external.panelFrame.maxY, external.bounds.maxY, "Expanded reader remains at the full top edge")
    }
    func testMeasuredMacBookHousingKeepsBothControlsOutsidePhysicalCamera() {
        // Captured from this MacBook Pro: 1512×982, safe top 32, 663.5-point
        // shoulders, 185-point camera. Check offsets and alternate logical scales.
        for origin in [CGPoint.zero, CGPoint(x: -1512, y: 1440)] {
            for factor in [1.0, 1.25] {
                let bounds = CGRect(origin: origin, size: CGSize(width: 1512 * factor, height: 982 * factor))
                let height = 32 * factor
                let left = CGRect(x: bounds.minX, y: bounds.maxY - height, width: 663.5 * factor, height: height)
                let right = CGRect(x: bounds.minX + 848.5 * factor, y: bounds.maxY - height, width: left.width, height: height)
                let measured = NotchDisplay.measureCameraHousing(bounds: bounds, safeTop: height, leftArea: left, rightArea: right, scale: 2)
                XCTAssertEqual(measured, ceil(185 * factor * 2) / 2)
                let display = screen(1, bounds, band: height + 1, housing: measured)
                let layout = display.layout
                let leftButtonEdge = display.panelFrame.minX + layout.leftControl.maxX
                let rightButtonEdge = display.panelFrame.minX + layout.rightControl.minX
                XCTAssertLessThanOrEqual(leftButtonEdge, left.maxX - 8)
                XCTAssertGreaterThanOrEqual(rightButtonEdge, right.minX + 8)
                XCTAssertGreaterThan(layout.timerControl.minX, layout.rightControl.maxX)
                XCTAssertEqual(display.compactFrame.width, measured + 144)
                XCTAssertEqual(display.compactFrame.minX, display.panelFrame.minX + layout.leftControl.minX - 12)
                XCTAssertEqual(display.compactFrame.maxX, display.panelFrame.minX + layout.rightControl.maxX + 12)
                XCTAssertTrue(layout.compactBounds.contains(layout.leftControl))
                XCTAssertTrue(layout.compactBounds.contains(layout.rightControl))
                // A temporarily absent safe inset must not discard valid shoulders.
                XCTAssertEqual(NotchDisplay.measureCameraHousing(bounds: bounds, safeTop: 0, leftArea: left, rightArea: right, scale: 2), measured)
            }
        }
    }
    func testMissingAuxiliaryAreasNeverCollapseAKnownNotchIntoExternalLayout() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for left: CGRect? in [nil, .zero] {
            let housing = NotchDisplay.measureCameraHousing(bounds: bounds, safeTop: 32, leftArea: left, rightArea: nil, scale: 2)
            XCTAssertGreaterThanOrEqual(housing, 185)
            XCTAssertEqual(NotchDisplay.measureCameraHousing(bounds: bounds, safeTop: 0, leftArea: left, rightArea: nil, scale: 2), 0)
        }
    }
    @MainActor func testClickUsesCapturedEventCoordinatesForLocalAndGlobalEvents() throws {
        _ = NSApplication.shared
        let a = screen(1, CGRect(x: 0, y: 0, width: 1512, height: 982), band: 33, housing: 185)
        let b = screen(2, CGRect(x: 1512, y: -458, width: 2560, height: 1440), band: 30)
        var selection = NotchDisplaySelection()
        selection.initialize(preferred: 2, available: [a, b])
        let global = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 800, y: 600), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(selection.click(event: global, available: [a, b]))
        XCTAssertEqual(selection.selectedID, 1)
        let window = NSWindow(contentRect: CGRect(x: 1600, y: -300, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(CGRect(x: 1600, y: -300, width: 400, height: 300), display: false)
        // Headless XCTest windows have no registered WindowServer number. Supply
        // the associated window directly, without displaying a test window.
        let local = WindowClick()
        local.associatedWindow = window
        XCTAssertTrue(selection.click(event: local, available: [a, b]))
        XCTAssertEqual(selection.selectedID, 2)
        selection.setLocked(true)
        XCTAssertFalse(selection.click(event: global, available: [a, b]))
        XCTAssertEqual(selection.selectedID, 2)
    }
    func testClickSelectionLocksThroughPauseAndRelocatesOnDisconnect() {
        let a = screen(1, CGRect(x: 0, y: 0, width: 1512, height: 982), band: 38, housing: 190)
        let b = screen(2, CGRect(x: 0, y: 982, width: 1920, height: 1080), band: 24)
        var selection = NotchDisplaySelection()
        selection.initialize(preferred: 2, available: [a, b]); XCTAssertEqual(selection.selectedID, 2)
        XCTAssertTrue(selection.click(at: CGPoint(x: 100, y: 100), available: [a, b]))
        selection.setLocked(true)
        XCTAssertFalse(selection.click(at: CGPoint(x: 100, y: 1200), available: [a, b]))
        XCTAssertEqual(selection.selectedID, 1)
        XCTAssertTrue(selection.reconcile(available: [b], fallback: 2))
        XCTAssertEqual(selection.selectedID, 2); XCTAssertTrue(selection.locked)
        XCTAssertFalse(selection.reconcile(available: [b], fallback: 2))
        selection.setLocked(false)
        XCTAssertTrue(selection.click(at: CGPoint(x: 100, y: 100), available: [a, b]))
    }
}

private final class WindowClick: NSEvent {
    var associatedWindow: NSWindow?
    override var window: NSWindow? { associatedWindow }
    override var locationInWindow: NSPoint { NSPoint(x: 100, y: 100) }
}
