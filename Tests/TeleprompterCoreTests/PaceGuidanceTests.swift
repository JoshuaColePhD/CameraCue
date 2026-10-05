import XCTest
@testable import TeleprompterCore

final class PaceGuidanceTests: XCTestCase {
    func testHintsOnlyAfterMeaningfulDrift() {
        XCTAssertNil(PaceGuidance.hint(elapsed: 10, duration: 300, progress: 0))
        XCTAssertNil(PaceGuidance.hint(elapsed: 60, duration: 300, progress: 0.21))
        XCTAssertEqual(PaceGuidance.hint(elapsed: 60, duration: 300, progress: 0.10), .speedUp)
        XCTAssertEqual(PaceGuidance.hint(elapsed: 60, duration: 300, progress: 0.35), .slowDown)
    }

    func testOvertimeHintContinuesUntilScriptIsComplete() {
        XCTAssertEqual(PaceGuidance.hint(elapsed: 301, duration: 300, progress: 0.8), .overtime)
        XCTAssertEqual(PaceGuidance.hint(elapsed: 301, duration: 300, progress: 0.96), .overtime)
        XCTAssertNil(PaceGuidance.hint(elapsed: 301, duration: 300, progress: 1))
    }
    func testHysteresisDoesNotFlickerAtWarningBoundary() {
        XCTAssertNil(PaceGuidance.hint(elapsed: 60, duration: 300, progress: 0.125))
        XCTAssertEqual(PaceGuidance.hint(elapsed: 60, duration: 300, progress: 0.125, previous: .speedUp), .speedUp)
        XCTAssertNil(PaceGuidance.hint(elapsed: 60, duration: 300, progress: 0.18, previous: .speedUp))
    }
    func testConfirmationAndSpacedRemindersIgnoreCallbackFrequency() {
        var feedback = PaceFeedback()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(feedback.update(.speedUp, at: start))
        for offset in stride(from: 0.1, through: 2.9, by: 0.1) {
            XCTAssertFalse(feedback.update(.speedUp, at: start.addingTimeInterval(offset)))
        }
        XCTAssertNil(feedback.hint)
        XCTAssertTrue(feedback.update(.speedUp, at: start.addingTimeInterval(3)))
        XCTAssertEqual(feedback.hint, .speedUp)
        XCTAssertFalse(feedback.update(.speedUp, at: start.addingTimeInterval(14.9)))
        XCTAssertTrue(feedback.update(.speedUp, at: start.addingTimeInterval(15)))
        XCTAssertFalse(feedback.update(nil, at: start.addingTimeInterval(16)))
        XCTAssertFalse(feedback.update(nil, at: start.addingTimeInterval(19)))
        XCTAssertNil(feedback.hint)
        XCTAssertTrue(feedback.update(.overtime, at: start.addingTimeInterval(20)))
        feedback.reset()
        XCTAssertNil(feedback.hint)
    }
    func testBriefExcursionsDoNotFlash() {
        var feedback = PaceFeedback()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(feedback.update(.speedUp, at: start))
        XCTAssertFalse(feedback.update(nil, at: start.addingTimeInterval(2)))
        XCTAssertFalse(feedback.update(.slowDown, at: start.addingTimeInterval(3)))
        XCTAssertFalse(feedback.update(nil, at: start.addingTimeInterval(5)))
        XCTAssertNil(feedback.hint)
    }
}
