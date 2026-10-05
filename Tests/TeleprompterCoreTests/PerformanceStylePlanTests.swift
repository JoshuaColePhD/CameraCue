import XCTest
@testable import TeleprompterCore

final class PerformanceStylePlanTests: XCTestCase {
    func testReflowKeepsSpokenWordsAndAnnotations() {
        let source = "[Pause.]\nImagine somebody has been trying to break into your Minecraft base for TEN YEARS.\nTen. Years."
        let plan = PerformanceLayout.localPlan(for: source)
        XCTAssertTrue(plan.isValid(for: source))
        XCTAssertTrue(plan.formattedBody.contains("[Pause.]"))
        XCTAssertGreaterThan(plan.formattedBody.components(separatedBy: "\n").count, 3)
    }

    func testInvalidGeneratedPhraseIsRejected() {
        let document = ScriptDocument("The Trojans dragged the horse inside.")
        let good = PerformanceMoment(lineID: 0, phrase: "horse", tone: .cyan, scale: .large, pauseAfter: true)
        let bad = PerformanceMoment(lineID: 0, phrase: "dragon", tone: .coral, scale: .huge, pauseAfter: false)
        XCTAssertNotNil(PerformanceLayout.validatedMoment(good, in: document))
        XCTAssertNil(PerformanceLayout.validatedMoment(bad, in: document))
    }

    func testShortShoutedWordGetsLargestTreatment() {
        let plan = PerformanceLayout.localPlan(for: "GOOD.\nfor TEN YEARS.")
        XCTAssertEqual(plan.moments.first?.phrase, "GOOD")
        XCTAssertEqual(plan.moments.first?.scale, .huge)
        XCTAssertEqual(plan.moments.last?.scale, .large)
    }
}
