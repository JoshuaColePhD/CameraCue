import XCTest
import AppKit
import QuartzCore
@testable import TeleprompterApp

@MainActor final class NotchMotionTests: XCTestCase {
    private func fixture(screen: NSScreen? = NSScreen.main) -> (NSPanel, NotchSurface) {
        _ = NSApplication.shared
        let model = TeleprompterModel(defaults: nil)
        let surface = NotchSurface(model: model)
        surface.reduceMotionOverride = false
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 548, height: 248),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false
        panel.contentView = surface
        if let screen { panel.setFrameOrigin(CGPoint(x: screen.frame.midX - 274, y: screen.frame.maxY - 248)) }
        surface.configure(size: CGSize(width: 548, height: 248), housing: 0, header: 24, scale: screen?.backingScaleFactor ?? 2)
        surface.setExpanded(false, animated: false)
        panel.orderFront(nil)
        CATransaction.flush()
        return (panel, surface)
    }
    private func wait(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

    func testReversalsUseVisiblePositionsAndOnlyLatestTransitionCompletes() async throws {
        let (panel, surface) = fixture(); defer { panel.close() }
        let buttons = surface.subviews.compactMap { $0 as? NSButton }
        var completions = 0
        surface.onAnimationFinished = { completions += 1 }
        surface.setExpanded(true, animated: true)
        try await wait(0.10)
        let visible = try XCTUnwrap(buttons[3].layer?.presentation()).frame
        let modelFrame = buttons[3].frame
        XCTAssertNotEqual(visible.origin, modelFrame.origin)
        let point = surface.convert(CGPoint(x: visible.minX + 15, y: visible.midY), to: surface.superview)
        XCTAssertTrue(surface.hitTest(point) === buttons[3], "Brand hit testing must follow its visible position")
        surface.setExpanded(false, animated: true)
        let reverse = try XCTUnwrap(buttons[3].layer?.animation(forKey: "headerPosition") as? CABasicAnimation)
        let source = try XCTUnwrap(reverse.fromValue as? CGPoint)
        XCTAssertEqual(source.x - buttons[3].frame.width * (buttons[3].layer?.anchorPoint.x ?? 0), visible.minX, accuracy: 3)
        XCTAssertEqual(reverse.duration, NotchMotion.closeDuration)
        XCTAssertNil(buttons[3].layer?.animation(forKey: "bounds"), "Logo bounds must not interpolate")
        try await wait(0.04)
        surface.setExpanded(true, animated: true)
        try await wait(0.40)
        XCTAssertFalse(surface.isTransitioning)
        XCTAssertEqual(buttons[3].frame.minX, 32)
        XCTAssertEqual(completions, 1, "Canceled transitions cannot settle a later one")
    }

    func testIncomingControlsStayInactiveUntilSettledAndOutgoingControlsLoseAccess() async throws {
        let (panel, surface) = fixture(); defer { panel.close() }
        let buttons = surface.subviews.compactMap { $0 as? NSButton }
        var timerClicks = 0
        surface.onAdjustTimer = { _ in timerClicks += 1 }
        surface.setExpanded(true, animated: true)
        XCTAssertTrue(surface.isTransitioning)
        XCTAssertFalse(buttons[2].isAccessibilityEnabled())
        buttons[2].performClick(nil)
        XCTAssertEqual(timerClicks, 0)
        try await wait(0.40)
        XCTAssertTrue(buttons[2].isAccessibilityEnabled())
        buttons[2].performClick(nil)
        XCTAssertEqual(timerClicks, 1)
        surface.setExpanded(false, animated: true)
        XCTAssertFalse(buttons[2].isAccessibilityEnabled())
        XCTAssertFalse(buttons[2].isHidden, "Outgoing content can fade without accepting clicks")
        try await wait(0.32)
        XCTAssertTrue(buttons[2].isHidden)
    }

    func testReduceMotionSettlesImmediately() throws {
        let (panel, surface) = fixture(); defer { panel.close() }
        surface.reduceMotionOverride = true
        surface.setExpanded(true, animated: true)
        XCTAssertFalse(surface.isTransitioning)
        for button in surface.subviews.compactMap({ $0 as? NSButton }) {
            XCTAssertNil(button.layer?.animation(forKey: "headerPosition"))
            XCTAssertNil(button.layer?.animation(forKey: "headerReveal"))
        }
        let reader = try XCTUnwrap(surface.subviews.first?.subviews.first)
        XCTAssertNil(reader.layer?.animation(forKey: "reveal"))
    }

    func testProfileAvailableDisplaysWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CAMERACUE_PROFILE_MOTION"] == "1" else {
            throw XCTSkip("Opt-in hardware profiling of isolated native surfaces")
        }
        for screen in NSScreen.screens {
            let (panel, surface) = fixture(screen: screen); defer { panel.close() }
            panel.ignoresMouseEvents = true
            let sampler = MotionFrameSampler()
            let link = screen.displayLink(target: sampler, selector: #selector(MotionFrameSampler.tick(_:)))
            link.add(to: .main, forMode: .common)
            try await wait(0.15)
            for _ in 0..<12 {
                surface.setExpanded(true, animated: true); try await wait(0.36)
                surface.setExpanded(false, animated: true); try await wait(0.30)
            }
            link.invalidate()
            let intervals = sampler.intervals.sorted()
            let p95 = intervals.isEmpty ? 0 : intervals[min(intervals.count - 1, Int(Double(intervals.count) * 0.95))]
            let gaps = intervals.filter { $0 > 0.05 }.count
            print("MOTION_PROFILE display=\(screen.localizedName) scale=\(screen.backingScaleFactor) maxRefreshHz=\(screen.maximumFramesPerSecond) samples=\(intervals.count) p95_ms=\(p95 * 1000) max_ms=\((intervals.last ?? 0) * 1000) gaps_over_50ms=\(gaps)")
            XCTAssertGreaterThan(intervals.count, 30)
            XCTAssertLessThanOrEqual(gaps, 1, "Repeated >50ms callback stalls need investigation")
        }
    }
}

@MainActor private final class MotionFrameSampler: NSObject {
    var previous: CFTimeInterval?
    var intervals: [Double] = []
    @objc func tick(_ link: CADisplayLink) {
        let time = CACurrentMediaTime()
        if let previous { intervals.append(time - previous) }
        previous = time
    }
}
