import XCTest
import AppKit
import Combine
@testable import TeleprompterApp

@MainActor final class NotchResizeTests: XCTestCase {
    func testResizingPreservesTopCameraControlsAndDisplayLimits() {
        for scale: CGFloat in [1, 2] {
            for origin in [CGPoint.zero, CGPoint(x: -1512, y: 1440)] {
                for housing: CGFloat in [0, 185] {
                    let display = NotchDisplay(id: 1, bounds: CGRect(origin: origin, size: CGSize(width: 1512, height: 982)),
                        visibleBounds: CGRect(x: origin.x, y: origin.y + 82, width: 1512, height: 867),
                        cameraHousing: housing, safeTop: housing > 0 ? 32 : 0, scale: scale)
                    let compact = display.compactFrame
                    for requested: CGFloat in [-100, 248, 391.7, 680, 2000] {
                        let layout = display.layout(preferredHeight: requested)
                        let frame = display.panelFrame(preferredHeight: requested)
                        XCTAssertEqual(frame.maxY, display.bounds.maxY)
                        XCTAssertEqual(frame.midX, display.bounds.midX)
                        XCTAssertEqual(frame.width, display.panelFrame.width)
                        XCTAssertEqual(layout.leftControl, display.layout.leftControl)
                        XCTAssertEqual(layout.rightControl, display.layout.rightControl)
                        XCTAssertEqual(layout.timerControl, display.layout.timerControl)
                        XCTAssertEqual(display.compactFrame, compact)
                        XCTAssertTrue(display.readerHeightRange.contains(frame.height))
                        XCTAssertGreaterThanOrEqual(frame.minY, display.visibleBounds.minY + 24)
                        XCTAssertEqual(frame.height * scale, floor(frame.height * scale))
                    }
                }
            }
        }
    }

    func testSavedPreferenceSurvivesRelaunchAndTemporarySmallerDisplay() throws {
        let suite = "CameraCue.resize-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = NotchController(defaults: defaults)
        XCTAssertEqual(controller.preferredReaderHeight, 248)
        var notifications = 0
        let observer = controller.objectWillChange.sink { notifications += 1 }
        controller.setReaderHeight(620)
        controller.setReaderHeight(620)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(NotchController(defaults: defaults).preferredReaderHeight, 620)
        let small = NotchDisplay(id: 2, bounds: CGRect(x: 0, y: -600, width: 1024, height: 600),
                                 visibleBounds: CGRect(x: 0, y: -540, width: 1024, height: 516))
        XCTAssertEqual(small.layout(preferredHeight: controller.preferredReaderHeight).size.height, 450)
        XCTAssertEqual(NotchReaderSize.load(from: defaults), 620, "A smaller display must not overwrite the user's preference")
        defaults.set(Double.nan, forKey: NotchReaderSize.preferenceKey)
        XCTAssertEqual(NotchReaderSize.load(from: defaults), 248)
        withExtendedLifetime(observer) {}
    }

    func testNativeDragUsesScreenCoordinatesAsWindowBottomMoves() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 548, height: 248),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let handle = NotchResizeHandle(frame: CGRect(x: 48, y: 0, width: 452, height: 16))
        window.contentView?.addSubview(handle)
        var session: NotchResizeSession?
        var heights: [CGFloat] = []
        var finishes = 0
        handle.onBegin = { session = NotchResizeSession(height: window.frame.height, screenY: $0.y) }
        handle.onDrag = { point in
            guard let session else { return }
            let height = session.height(atScreenY: point.y)
            heights.append(height)
            window.setFrame(CGRect(x: 300, y: 548 - height, width: 548, height: height), display: false)
        }
        handle.onEnd = { finishes += 1; session = nil }
        func event(screenY: CGFloat) -> ResizeEvent {
            let event = ResizeEvent()
            event.associatedWindow = window
            event.point = window.convertPoint(fromScreen: CGPoint(x: 574, y: screenY))
            return event
        }
        handle.mouseDown(with: event(screenY: 308))
        handle.mouseDragged(with: event(screenY: 208))
        handle.mouseDragged(with: event(screenY: 158))
        handle.mouseUp(with: event(screenY: 158))
        XCTAssertEqual(heights, [348, 398, 398], "Moving the origin cannot amplify the drag delta")
        XCTAssertEqual(window.frame.maxY, 548)
        XCTAssertFalse(handle.isDragging)
        XCTAssertEqual(finishes, 1)
        handle.mouseDragged(with: event(screenY: 120))
        XCTAssertEqual(heights.count, 3)
    }

    func testResizingKeepsReaderMountedAndGripOnlyInteractiveWhenExpanded() throws {
        _ = NSApplication.shared
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        let surface = NotchSurface(model: TeleprompterModel(defaults: nil))
        parent.addSubview(surface)
        surface.configure(size: CGSize(width: 548, height: 248), housing: 185, header: 33, scale: 2)
        let reader = try XCTUnwrap(surface.subviews.first?.subviews.first)
        let buttons = surface.subviews.compactMap { $0 as? NSButton }
        surface.setExpanded(true, animated: false)
        let frames = buttons.map(\.frame)
        for height: CGFloat in [248, 420, 680, 248] {
            surface.configure(size: CGSize(width: 548, height: height), housing: 185, header: 33, scale: 2)
            surface.setExpanded(true, animated: false)
            XCTAssertTrue(surface.subviews.first?.subviews.first === reader)
            XCTAssertEqual(reader.frame.width, 548)
            XCTAssertEqual(reader.frame.height, height - 33 - 16)
            XCTAssertEqual(buttons.map(\.frame), frames)
            let grip = surface.resizeHandle
            let point = surface.convert(CGPoint(x: grip.frame.midX, y: grip.frame.midY), to: parent)
            XCTAssertTrue(surface.hitTest(point) === grip)
            XCTAssertEqual((grip.accessibilityValue() as? NSNumber)?.doubleValue, Double(height))
            surface.setExpanded(false, animated: false)
            XCTAssertNil(surface.hitTest(point))
            XCTAssertTrue(grip.isHidden)
            XCTAssertEqual(surface.accessibilityChildren()?.count, 2)
            XCTAssertFalse(grip.accessibilityPerformIncrement())
        }
        let preview = NotchSurface(model: TeleprompterModel(defaults: nil), interactive: false)
        preview.setExpanded(true, animated: false)
        var changes = 0
        preview.resizeHandle.onAdjust = { _ in changes += 1 }
        XCTAssertFalse(preview.resizeHandle.accessibilityPerformIncrement())
        XCTAssertEqual(changes, 0)
    }

    func testGripResetAccessibilityAndCollapseCancelTracking() {
        _ = NSApplication.shared
        let surface = NotchSurface(model: TeleprompterModel(defaults: nil))
        surface.configure(size: CGSize(width: 548, height: 420), housing: 185, header: 33, scale: 2)
        surface.setExpanded(true, animated: false)
        let grip = surface.resizeHandle
        var adjustments: [CGFloat] = []
        var resets = 0, finishes = 0
        grip.onAdjust = { adjustments.append($0) }
        grip.onSetHeight = { adjustments.append($0) }
        grip.onReset = { resets += 1 }
        grip.onEnd = { finishes += 1 }
        XCTAssertTrue(grip.accessibilityPerformIncrement())
        XCTAssertTrue(grip.accessibilityPerformDecrement())
        XCTAssertEqual(adjustments, [40, -40])
        grip.setAccessibilityValue(NSNumber(value: 520))
        XCTAssertEqual(adjustments, [40, -40, 520])
        let doubleClick = ResizeEvent(); doubleClick.clicks = 2
        grip.mouseDown(with: doubleClick)
        XCTAssertEqual(resets, 1)
        XCTAssertFalse(grip.isDragging)
        grip.mouseDown(with: ResizeEvent())
        XCTAssertTrue(grip.isDragging)
        surface.setExpanded(false, animated: false)
        XCTAssertFalse(grip.isDragging)
        XCTAssertEqual(finishes, 1)
        grip.setAccessibilityValue(NSNumber(value: 600))
        XCTAssertEqual(adjustments, [40, -40, 520], "Hidden resize controls cannot change the height")
        grip.cancelDrag()
        XCTAssertEqual(finishes, 1)
    }
}

private final class ResizeEvent: NSEvent {
    var associatedWindow: NSWindow?
    var point: CGPoint = .zero
    var clicks = 1
    override var window: NSWindow? { associatedWindow }
    override var locationInWindow: NSPoint { point }
    override var clickCount: Int { clicks }
}
