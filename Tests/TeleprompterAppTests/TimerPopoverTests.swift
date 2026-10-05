import XCTest
import AppKit
import SwiftUI
@testable import TeleprompterApp

@MainActor final class TimerPopoverTests: XCTestCase {
    func testTimerPopoverFitsScreenEdgesAndKeepsSizeAcrossDirections() async throws {
        _ = NSApplication.shared
        let model = TeleprompterModel(defaults: nil)
        model.timerMode = .countdown
        var captured = false
        for screen in NSScreen.screens {
            for fraction: CGFloat in [0.05, 0.5, 0.95] {
                let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 80, height: 28),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.setFrameOrigin(CGPoint(x: screen.frame.minX + (screen.frame.width - 80) * fraction,
                    y: screen.frame.maxY - 28))
                let anchor = NSButton(frame: CGRect(x: 0, y: 0, width: 80, height: 28))
                panel.contentView = anchor; panel.orderFront(nil)
                let popover = NSPopover()
                popover.behavior = .transient
                popover.animates = false
                let host = NSHostingController(rootView: TimerSettingsView(model: model, onClose: { [weak popover] in popover?.close() }))
                popover.contentViewController = host
                let screenAnchor = panel.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                popover.show(relativeTo: anchor.bounds, of: anchor,
                    preferredEdge: TimerPopoverPlacement.edge(anchor: screenAnchor, screen: screen.visibleFrame))
                try await Task.sleep(for: .milliseconds(120))
                let window = try XCTUnwrap(host.view.window)
                let initial = window.frame
                XCTAssertGreaterThan(initial.height, 300)
                XCTAssertGreaterThanOrEqual(initial.minX, screen.frame.minX - 1)
                XCTAssertLessThanOrEqual(initial.maxX, screen.frame.maxX + 1)
                XCTAssertGreaterThanOrEqual(initial.minY, screen.frame.minY)
                XCTAssertLessThanOrEqual(initial.maxY, screen.frame.maxY + 1)
                if !captured && ProcessInfo.processInfo.environment["CAMERACUE_TIMER_SNAPSHOTS"] == "1" {
                    captured = true
                    if let rep = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                        host.view.cacheDisplay(in: host.view.bounds, to: rep)
                        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/cameracue-timer-countdown.png"))
                    }
                }
                model.timerMode = .countUp
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(window.frame.height, initial.height, accuracy: 1, "Direction changes must not jump the popover")
                model.timerMode = .countdown
                model.countdownMinutes = 180
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(window.frame.height, initial.height, accuracy: 1)
                model.countdownMinutes = 5
                popover.close(); panel.close()
            }
        }
    }
}
