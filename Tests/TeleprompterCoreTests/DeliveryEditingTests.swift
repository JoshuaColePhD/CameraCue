import XCTest
@testable import TeleprompterCore

final class DeliveryEditingTests: XCTestCase {
    func testReflowPreservesInlineDeliveryCues() {
        let source = "Hello [lean toward the camera slowly] my friends, welcome to our story."
        let plan = PerformanceLayout.localPlan(for: source)
        XCTAssertTrue(plan.isValid(for: source))
        XCTAssertFalse(ScriptDocument(plan.formattedBody).tokens.contains("slowly"))
    }
    func testPresetsKeepWordsAndSuggestionsAvailable() {
        let source = "Look at that GIANT HORSE!\n[Pause.]\nWe should investigate."
        let original = PerformanceLayout.localPlan(for: source)
        for preset in ReadingStylePreset.allCases {
            let plan = original.styled(preset, intensity: 0.6)
            XCTAssertTrue(plan.isValid(for: source))
            XCTAssertEqual(plan.moments, original.moments)
            XCTAssertNotEqual(plan.id, original.id)
            if preset == .minimal { XCTAssertNil(plan.displayMoment(forLine: original.moments[0].lineID)) }
        }
        XCTAssertNil(original.styled(.expressive, intensity: 0).displayMoment(forLine: original.moments[0].lineID))
    }
    func testPhraseEditsAndKeepTogetherPreserveWordsAndRemapLaterMoments() throws {
        let source = "One little horse.\nTwo mighty walls.\nTHREE!"
        let plan = PerformanceLayout.localPlan(for: source).styled(.expressive, intensity: 1)
        let joined = try XCTUnwrap(plan.editing(lineID: 0, phrase: "One little horse. Two mighty walls.", treatment: .keepTogether))
        XCTAssertEqual(joined.formattedBody, "One little horse. Two mighty walls.\nTHREE!")
        XCTAssertEqual(joined.moments.last?.lineID, 1)
        XCTAssertTrue(joined.isValid(for: source))
        let emphasis = try XCTUnwrap(joined.editing(lineID: 0, phrase: "little horse", treatment: .emphasize))
        XCTAssertEqual(emphasis.displayMoment(forLine: 0)?.phrase, "little horse")
        let pause = try XCTUnwrap(emphasis.editing(lineID: 0, phrase: "Two mighty walls.", treatment: .pause))
        XCTAssertEqual(pause.displayMoment(forLine: 0)?.pauseAfter, true)
        XCTAssertTrue(pause.isValid(for: source))
        XCTAssertNil(plan.editing(lineID: 0, phrase: "invented words", treatment: .emphasize))
        XCTAssertNil(plan.editing(lineID: 0, phrase: "THREE!", treatment: .emphasize))
    }
    func testExistingSavedPlansDecodeWithoutNewStyleOptions() throws {
        let old = PerformanceLayout.localPlan(for: "A short line.")
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(PerformanceStylePlan.self, from: data)
        XCTAssertNil(decoded.preset)
        XCTAssertTrue(decoded.isValid(for: "A short line."))
        let styled = decoded.styled(.minimal, intensity: 0.4)
        let saved = try JSONDecoder().decode(PerformanceStylePlan.self, from: JSONEncoder().encode(styled))
        XCTAssertEqual(saved.preset, .minimal)
        XCTAssertEqual(saved.intensity, 0.4)
    }
}
