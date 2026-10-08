import XCTest
import AppKit
import SwiftUI
@testable import TeleprompterApp

final class StudioLayoutTests: XCTestCase {
    func testGridBreakpointsUseContentWidth() {
        XCTAssertEqual(StudioLayout.columns(for: 539), 1)
        XCTAssertEqual(StudioLayout.columns(for: 540), 2)
        XCTAssertEqual(StudioLayout.columns(for: 819), 2)
        XCTAssertEqual(StudioLayout.columns(for: 820), 3)
    }
    func testInspectorAndCameraBreakpoints() {
        XCTAssertFalse(StudioLayout.initiallyShowsPreview(width: 899))
        XCTAssertTrue(StudioLayout.initiallyShowsPreview(width: 900))
        XCTAssertTrue(StudioLayout.stacksCamera(width: 759))
        XCTAssertFalse(StudioLayout.stacksCamera(width: 760))
    }
    func testPreviewPreservesUnicodeAndExcludesDeliveryNotes() {
        let source = "[Whisper.]\nCafé 👋\nOne\nTwo\nThree\nFour\nFive\nSix\nSeven\nEight"
        let summary = ScriptTextSummary(body: source)
        XCTAssertTrue(summary.previewExcerpt.contains("Café 👋"))
        XCTAssertFalse(summary.previewExcerpt.contains("Whisper"))
        XCTAssertTrue(summary.previewExcerpt.contains("Seven"))
        XCTAssertEqual(summary.excerptLines.count, 3)
    }
}

@MainActor final class StudioWorkflowBarTests: XCTestCase {
    func testWorkflowStaysCenteredAcrossStepsAndCompactWidths() async throws {
        _ = NSApplication.shared
        for width in [CGFloat(666), 996] {
            for step in StudioStep.allCases {
                let host = NSHostingView(rootView: StudioWorkflowBar(step: .constant(step), width: width,
                    onScripts: {}, onCameraSettings: {}))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 70),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let control = try XCTUnwrap(segmentedControl(in: host))
                let frame = host.convert(control.bounds, from: control)
                XCTAssertEqual(frame.midX, width / 2, accuracy: 1, "Workflow shifts in \(step) at width \(width)")
                XCTAssertGreaterThanOrEqual(frame.minX, 24)
                XCTAssertLessThanOrEqual(frame.maxX, width - 24)
            }
        }
    }
    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.lazy.compactMap { self.segmentedControl(in: $0) }.first
    }
}
