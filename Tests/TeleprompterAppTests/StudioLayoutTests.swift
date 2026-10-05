import XCTest
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
