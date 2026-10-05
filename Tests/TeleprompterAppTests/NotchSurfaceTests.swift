import XCTest
import AppKit
import QuartzCore
import Combine
import TeleprompterCore
@testable import TeleprompterApp

@MainActor final class NotchSurfaceTests: XCTestCase {
    func testExpandedBrandAndCaretMoveToLeftEdgeOnMacBookAndExternalDisplay() throws {
        _ = NSApplication.shared
        for housing: CGFloat in [0, 185, 190, 220] {
            let layout = NotchLayout(size: CGSize(width: max(548, housing + 368), height: 248), housing: housing, header: 34)
            let surface = NotchSurface(model: TeleprompterModel(defaults: nil))
            surface.configure(size: layout.size, housing: housing, header: 34, scale: 2)
            surface.setExpanded(true, animated: false)
            let buttons = surface.subviews.compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons[3].frame.minX, 32)
            XCTAssertEqual(buttons[0].frame.minX, buttons[3].frame.maxX + 2)
            XCTAssertLessThan(layout.listeningIndicator(expanded: true).maxX, layout.recordControl(expanded: true).minX)
            if housing > 0 {
                XCTAssertLessThan(layout.listeningIndicator(expanded: true).maxX, layout.size.width / 2 - housing / 2)
            }
            surface.setExpanded(false, animated: false)
            XCTAssertEqual(buttons[3].frame, layout.leftControl)
            XCTAssertEqual(buttons[0].frame, layout.rightControl)
        }
    }
    func testExternalSurfaceHeaderClicksAndLeftAlignedExpandedControls() throws {
        _ = NSApplication.shared
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let surface = NotchSurface(model: TeleprompterModel(defaults: nil))
        surface.configure(size: CGSize(width: 548, height: 248), housing: 0, header: 24, scale: 1)
        parent.addSubview(surface)
        let buttons = surface.subviews.compactMap { $0 as? NSButton }
        let layout = NotchLayout(size: CGSize(width: 548, height: 248), housing: 0, header: 24)
        XCTAssertEqual(layout.compactWidth, 220)
        var toggles = 0, timerClicks = 0, recordClicks = 0
        surface.onToggleReader = { toggles += 1 }
        surface.onAdjustTimer = { _ in timerClicks += 1 }
        surface.onRecord = { recordClicks += 1 }
        for expanded in [false, true, false] {
            surface.setExpanded(expanded, animated: false)
            let point = CGPoint(x: expanded ? 350 : 274, y: 12)
            let hit = try XCTUnwrap(surface.hitTest(surface.convert(point, to: parent)))
            XCTAssertTrue(hit === surface, "Empty header space must toggle the reader")
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: surface.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            hit.mouseDown(with: event)
            XCTAssertEqual(buttons[3].frame, layout.brandControl(expanded: expanded))
            XCTAssertEqual(buttons[0].frame, layout.chevronControl(expanded: expanded))
            if expanded {
                XCTAssertEqual(buttons[3].frame.minX, 32)
                XCTAssertEqual(buttons[0].frame.minX, layout.brandControl(expanded: true).maxX + 2)
                XCTAssertFalse(buttons[0].frame.intersects(buttons[3].frame))
                let caretPoint = CGPoint(x: buttons[0].frame.midX, y: 12)
                XCTAssertTrue(surface.hitTest(surface.convert(caretPoint, to: parent)) === buttons[0])
                let timerPoint = CGPoint(x: buttons[2].frame.midX, y: 12)
                XCTAssertTrue(surface.hitTest(surface.convert(timerPoint, to: parent)) === buttons[2])
                buttons[2].performClick(nil)
                buttons[1].performClick(nil)
            }
        }
        XCTAssertEqual(toggles, 3)
        XCTAssertEqual(timerClicks, 1)
        XCTAssertEqual(recordClicks, 1, "Record remains a separate action within the header")
    }
    func testPaceWarningPulsesAtTheTopWithoutMovingControlsAndHonorsReduceMotion() throws {
        _ = NSApplication.shared
        let model = TeleprompterModel(defaults: nil)
        let surface = NotchSurface(model: model)
        surface.configure(size: CGSize(width: 548, height: 248), housing: 190, header: 34, scale: 2)
        surface.updateControls(model: model, expanded: true)
        surface.setExpanded(true, animated: false)
        let buttons = surface.subviews.compactMap { $0 as? NSButton }
        let frames = buttons.map(\.frame)
        let banner = try XCTUnwrap(surface.subviews.last)
        let label = try XCTUnwrap(banner.subviews.first as? NSTextField)
        for hint in [PaceHint.speedUp, .slowDown, .overtime] {
            surface.updatePacing(hint, pulse: true, expanded: true, reduceMotion: false)
            XCTAssertEqual(label.stringValue, hint.title)
            XCTAssertFalse(banner.isHidden)
            XCTAssertEqual(banner.frame.minY, 36, "Warning belongs immediately under the hardware camera")
            XCTAssertLessThanOrEqual(banner.frame.maxY, 56, "Keep the script's first row unobstructed")
            XCTAssertEqual(buttons.map(\.frame), frames)
            let timer = buttons[2]
            XCTAssertEqual(timer.alignment, .right)
            XCTAssertNil(timer.image)
            XCTAssertEqual(timer.layer?.backgroundColor?.alpha, 0)
            XCTAssertTrue(timer.layer?.animationKeys()?.isEmpty ?? true, "Pacing cannot pulse the timer")
            XCTAssertTrue(timer.layer?.sublayers?.isEmpty ?? true, "Timer has no animated outline")
            let accent = try XCTUnwrap(banner.layer?.sublayers?.first)
            XCTAssertEqual(accent.animation(forKey: "pacePulse")?.duration, 2.4)
            surface.updatePacing(hint, pulse: true, expanded: true, reduceMotion: true)
            XCTAssertNil(accent.animation(forKey: "pacePulse"))
            XCTAssertEqual(label.stringValue, hint.title, "Reduce Motion retains the static message")
        }
        surface.setExpanded(false, animated: false)
        XCTAssertTrue(banner.isHidden)
        surface.updatePacing(nil, pulse: false, expanded: false, reduceMotion: false)
        XCTAssertNil(surface.currentPaceWarning)
        XCTAssertEqual(label.stringValue, "")
    }
    func testPreviewAndLiveControlsShareStateAndPreviewCannotReceiveClicks() async throws {
        _ = NSApplication.shared
        let model = TeleprompterModel(defaults: nil)
        model.mode = .manual
        model.load(ScriptRecord(id: UUID(), title: "Parity", body: "Hello world.", modifiedAt: .now))
        let live = NotchSurface(model: model), preview = NotchSurface(model: model, interactive: false)
        for surface in [live, preview] {
            surface.configure(size: CGSize(width: 548, height: 248), housing: 0, header: 30, scale: 1)
            surface.setExpanded(true, animated: false)
        }
        await model.start()
        for paused in [false, true] {
            if paused { model.pause() }
            let date = Date()
            live.updateControls(model: model, expanded: true, at: date)
            preview.updateControls(model: model, expanded: true, at: date)
            let actual = live.subviews.compactMap { $0 as? NSButton }
            let mirrored = preview.subviews.compactMap { $0 as? NSButton }
            XCTAssertEqual(actual.map(\.frame), mirrored.map(\.frame))
            XCTAssertEqual(actual.map { $0.accessibilityLabel() }, mirrored.map { $0.accessibilityLabel() })
            XCTAssertEqual(actual[1].accessibilityLabel(), paused ? "Resume presentation" : "Stop prompting")
            XCTAssertEqual(actual[2].attributedTitle.string, mirrored[2].attributedTitle.string)
            XCTAssertTrue(mirrored.allSatisfy { !$0.isAccessibilityEnabled() })
            XCTAssertFalse(mirrored[1].accessibilityPerformPress())
            XCTAssertNil(preview.hitTest(CGPoint(x: 300, y: 15)))
        }
        live.setExpanded(false, animated: false)
        let buttons = live.subviews.compactMap { $0 as? NSButton }
        XCTAssertTrue(buttons[2].isHidden)
        XCTAssertEqual(live.accessibilityChildren()?.count, 3)
        model.finish()
    }
    func testExpansionDoesNotInvalidateTheStudioObjectGraph() {
        let controller = NotchController()
        var invalidations = 0
        let observation = controller.objectWillChange.sink { invalidations += 1 }
        controller.setExpanded(true)
        controller.setExpanded(false)
        XCTAssertEqual(invalidations, 0)
        withExtendedLifetime(observation) {}
    }
    func testRealMouseCoordinatesReachButtonsInUnflippedParent() throws {
        _ = NSApplication.shared
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let surface = NotchSurface(model: TeleprompterModel(defaults: nil))
        surface.configure(size: CGSize(width: 548, height: 248), housing: 190, header: 34, scale: 2)
        surface.setFrameOrigin(CGPoint(x: 40, y: 90))
        parent.addSubview(surface)
        let buttons = surface.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 4)
        XCTAssertFalse(parent.isFlipped)
        XCTAssertTrue(surface.isFlipped)
        for expanded in [false, true] {
            surface.setExpanded(expanded, animated: false)
            for button in buttons where !button.isHidden {
                let local = CGPoint(x: button.frame.midX, y: button.frame.midY)
                let parentPoint = surface.convert(local, to: parent)
                XCTAssertTrue(surface.hitTest(parentPoint) === button,
                              "Pointer hit must reach the visible button with reader expanded=\(expanded)")
            }
            let transparent = surface.convert(CGPoint(x: 1, y: 240), to: parent)
            XCTAssertNil(surface.hitTest(transparent))
        }
    }
    func testCompactControlsStayOutsideCameraAndInsideShell() {
        for housing in [0.0, 160, 190, 220] {
            for header in [22.0, 24, 32, 38] {
                var layout = NotchLayout(size: CGSize(width: 548, height: 248), housing: housing, header: header)
                let path = layout.path(state: .compact)
                if housing > 0 {
                    XCTAssertLessThan(layout.leftControl.maxX, layout.size.width / 2 - housing / 2)
                    XCTAssertGreaterThan(layout.rightControl.minX, layout.size.width / 2 + housing / 2)
                }
                for rect in [layout.leftControl, layout.rightControl] {
                    for point in [CGPoint(x: rect.minX + 2, y: rect.midY), CGPoint(x: rect.maxX - 2, y: rect.midY)] {
                        XCTAssertTrue(path.contains(point))
                    }
                }
                XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1)))
                XCTAssertFalse(path.contains(CGPoint(x: 274, y: 60)))
                let controls = [layout.leftControl, layout.rightControl, layout.playbackControl]
                layout.hasCompactPlayback = true
                for rect in controls {
                    for x in [rect.minX + 2, rect.maxX - 2] {
                        XCTAssertTrue(layout.path(state: .compact).contains(CGPoint(x: x, y: rect.midY)),
                                      "Ongoing compact takes must keep the whole Stop/Resume hit area inside the shell")
                    }
                }
                XCTAssertEqual(controls, [layout.leftControl, layout.rightControl, layout.playbackControl])
            }
        }
    }
    func testTimerStaysAtTopRightWithRoomForNegativeTimeAndCameraControls() throws {
        for housing: CGFloat in [0, 185, 190, 220] {
            let display = NotchDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleBounds: CGRect(x: 0, y: 82, width: 1512, height: 867), cameraHousing: housing)
            for height: CGFloat in [248, 487, 680] {
                let layout = display.layout(preferredHeight: height)
                XCTAssertEqual(layout.timerControl.maxX, layout.size.width - 32)
                XCTAssertEqual(layout.timerControl.midY, layout.header / 2)
                XCTAssertEqual(layout.timerControl.minX - layout.recordControl(expanded: true).maxX, 8)
                if housing > 0 {
                    XCTAssertGreaterThanOrEqual(layout.recordControl(expanded: true).minX, layout.size.width / 2 + housing / 2 + 6)
                }
                XCTAssertGreaterThanOrEqual(layout.timerControl.minX - layout.rightControl.maxX, 8)
                XCTAssertGreaterThan(layout.microphoneFrame.minX, layout.rightControl.maxX)
                XCTAssertLessThan(layout.microphoneFrame.maxX, layout.timerControl.minX)
                XCTAssertEqual(layout.leftControl.minX - layout.playbackControl.maxX, 8)
                for rect in [layout.timerControl, layout.microphoneFrame, layout.playbackControl] {
                    for x in [rect.minX, rect.maxX] {
                        for y in [rect.minY, rect.maxY] {
                            XCTAssertTrue(layout.path(state: .reader).contains(CGPoint(x: x, y: y)))
                        }
                    }
                }
                let longTime = NSAttributedString(string: "-180:00", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
                XCTAssertLessThan(longTime.size().width, layout.timerControl.width - 4)
            }
        }
    }
    func testAllShellStatesHaveMatchingCurveTopologyForInterpolation() {
        let layout = NotchLayout()
        func elements(_ path: CGPath) -> [CGPathElementType] {
            var types: [CGPathElementType] = []
            path.applyWithBlock { types.append($0.pointee.type) }
            return types
        }
        let compact = elements(layout.path(state: .compact))
        XCTAssertEqual(compact, elements(layout.path(state: .housing)))
        XCTAssertEqual(compact, elements(layout.path(state: .reader)))
        XCTAssertTrue(layout.path(state: .reader).contains(CGPoint(x: 274, y: 230)))
        XCTAssertFalse(layout.path(state: .reader).contains(CGPoint(x: 22, y: 247)))
    }
    func testRepeatedTransitionsKeepReaderIdentityAndFrameStable() throws {
        _ = NSApplication.shared
        let surface = NotchSurface(model: TeleprompterModel(defaults: nil))
        surface.configure(size: CGSize(width: 548, height: 248), housing: 190, header: 34, scale: 2)
        let container = try XCTUnwrap(surface.subviews.first)
        let reader = try XCTUnwrap(container.subviews.first)
        let frame = reader.frame
        XCTAssertEqual(frame.minY, 34)
        XCTAssertTrue(container.isFlipped)
        for _ in 0..<20 {
            surface.setExpanded(true, animated: true)
            surface.setExpanded(false, animated: true)
        }
        XCTAssertTrue(container.subviews.first === reader)
        XCTAssertEqual(reader.frame, frame)
        XCTAssertEqual(surface.accessibilityChildren()?.count, 2)
        surface.setExpanded(true, animated: false)
        XCTAssertGreaterThan(surface.accessibilityChildren()?.count ?? 0, 2)
        XCTAssertNotNil(surface.layer?.mask)
        XCTAssertEqual(reader.frame, frame)
        XCTAssertNil(surface.hitTest(CGPoint(x: 1, y: 240)))
    }
    func testReaderAndPlaybackButtonsDispatchDistinctActions() throws {
        _ = NSApplication.shared
        let model = TeleprompterModel(defaults: nil)
        model.mode = .manual
        model.load(ScriptRecord(id: UUID(), title: "Test", body: "One sentence.", modifiedAt: .now))
        let surface = NotchSurface(model: model)
        surface.configure(size: CGSize(width: 548, height: 248), housing: 190, header: 34, scale: 2)
        surface.updateControls(model: model, expanded: false)
        let buttons = surface.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 4)
        XCTAssertEqual(buttons[3].attributedTitle.string, "")
        XCTAssertNotNil(buttons[3].image)
        XCTAssertTrue(buttons[3].accessibilityLabel()?.contains("CameraCue") == true)
        for button in [buttons[0], buttons[3]] {
            XCTAssertEqual(button.layer?.backgroundColor?.alpha, 0, "Reader toggles have no pill background")
            XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        }
        XCTAssertLessThan(buttons[3].frame.maxX, 274 - 95)
        XCTAssertGreaterThan(buttons[0].frame.minX, 274 + 95)
        var opens = 0, plays = 0, timers = 0
        surface.onToggleReader = { opens += 1 }
        surface.onRecord = { plays += 1 }
        surface.onAdjustTimer = { _ in timers += 1 }
        buttons[0].performClick(nil)
        XCTAssertEqual(opens, 1); XCTAssertEqual(plays, 0)
        buttons[3].performClick(nil)
        XCTAssertEqual(opens, 2); XCTAssertEqual(plays, 0, "CameraCue opens the reader without starting")
        buttons[1].performClick(nil)
        XCTAssertTrue(buttons[1].isHidden)
        XCTAssertFalse(buttons[1].accessibilityPerformPress())
        XCTAssertEqual(opens, 2); XCTAssertEqual(plays, 0, "Hidden Record cannot start a take")
        XCTAssertTrue(buttons[2].isHidden)
        surface.setExpanded(true, animated: false)
        buttons[1].performClick(nil)
        XCTAssertEqual(plays, 1)
        buttons[2].performClick(nil)
        XCTAssertEqual(timers, 1); XCTAssertEqual(opens, 2); XCTAssertEqual(plays, 1)
    }

    func testRecordRequiresOpenReaderAndActiveStopRemainsAvailableWhenCollapsed() async throws {
        _ = NSApplication.shared
        for housing: CGFloat in [0, 185] {
            let model = TeleprompterModel(defaults: nil)
            model.mode = .manual
            model.load(ScriptRecord(id: UUID(), title: "Test", body: "One sentence.", modifiedAt: .now))
            let parent = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
            let surface = NotchSurface(model: model)
            surface.reduceMotionOverride = true
            parent.addSubview(surface)
            surface.configure(size: CGSize(width: 548, height: 248), housing: housing,
                              header: housing > 0 ? 33 : 24, scale: housing > 0 ? 2 : 1)
            surface.updateControls(model: model, expanded: false)
            surface.setExpanded(false, animated: false)
            let record = try XCTUnwrap(surface.subviews.compactMap { $0 as? NotchRecordControl }.first)
            let frame = record.frame
            let point = surface.convert(CGPoint(x: frame.midX, y: frame.midY), to: parent)
            XCTAssertTrue(record.isHidden)
            XCTAssertFalse(record.isAccessibilityEnabled())
            XCTAssertFalse(record.accessibilityPerformPress())
            XCTAssertEqual(surface.accessibilityChildren()?.count, 2)
            XCTAssertFalse(surface.hitTest(point) === record)

            surface.setExpanded(true, animated: false)
            surface.updateControls(model: model, expanded: true)
            XCTAssertFalse(record.isHidden)
            XCTAssertEqual(record.attributedTitle.string, "Record")
            let toggles = surface.subviews.compactMap { $0 as? NSButton }.filter {
                $0.accessibilityLabel()?.contains("reader") == true
            }
            XCTAssertEqual(toggles.count, 2)
            XCTAssertTrue(toggles.allSatisfy { $0.accessibilityLabel()?.contains("collapse reader") == true || $0.accessibilityLabel() == "Collapse reader" })
            let toggleFrames = toggles.map(\.frame)
            surface.setExpanded(false, animated: false)
            surface.updateControls(model: model, expanded: false)
            XCTAssertTrue(record.isHidden, "Closing the dropdown hides Record again")
            XCTAssertNotEqual(toggles.map(\.frame), toggleFrames, "Expanded controls group the caret beside the logo")
            XCTAssertTrue(toggles.allSatisfy { $0.accessibilityLabel()?.contains("open reader") == true || $0.accessibilityLabel() == "Open reader" })

            await model.start()
            surface.updateControls(model: model, expanded: false)
            XCTAssertFalse(record.isHidden)
            XCTAssertEqual(record.accessibilityLabel(), "Stop prompting")
            XCTAssertEqual(surface.accessibilityChildren()?.count, 3)
            XCTAssertTrue(surface.hitTest(point) === record)
            model.pause()
            surface.updateControls(model: model, expanded: false)
            XCTAssertFalse(record.isHidden)
            XCTAssertEqual(record.attributedTitle.string, "Resume")
            model.finish()
            surface.updateControls(model: model, expanded: false)
            XCTAssertTrue(record.isHidden, "A finished compact take must hide Record")
            XCTAssertFalse(surface.hitTest(point) === record)
            XCTAssertEqual(surface.accessibilityChildren()?.count, 2)
            surface.setExpanded(true, animated: false)
            XCTAssertFalse(record.isHidden)
            XCTAssertEqual(record.attributedTitle.string, "Record")
            let layout = NotchLayout(size: CGSize(width: 548, height: 248), housing: housing, header: 33)
            XCTAssertEqual(record.frame.maxX, layout.timerControl.minX - 8, "Record sits immediately before the timer")
        }
    }
}
