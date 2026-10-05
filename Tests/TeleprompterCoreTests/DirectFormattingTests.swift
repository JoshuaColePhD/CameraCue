import XCTest
@testable import TeleprompterCore

final class DirectFormattingTests: XCTestCase {
    func testRepeatedPhraseTargetsSecondOccurrence() throws {
        let body = "Wait here. Wait here. Then go."
        let selection = (body as NSString).range(of: "Wait here", options: .backwards)
        let tokens = try XCTUnwrap(ScriptTokenMap(body).tokens(intersecting: selection))
        XCTAssertEqual(tokens, 2..<4)
        let plan = try XCTUnwrap(PerformanceStylePlan(sourceBody: body, formattedBody: body, moments: [], usedAI: false).editing(tokens: tokens, treatment: .emphasize))
        let matches = PerformanceRanges.ranges(in: body, tokenOffset: 0, moments: plan.moments)
        XCTAssertEqual(matches.map(\.range), [selection])
        XCTAssertTrue(plan.isValid(for: body))
    }
    func testUnicodeAndContractionsMatchSpokenTokenCoordinates() throws {
        let body = "🎥 Café — we’re ready. [Smile.] 你好!"
        let map = ScriptTokenMap(body)
        XCTAssertEqual(map.ranges.count, ScriptDocument(body).tokens.count)
        let selected = (body as NSString).range(of: "we’re ready")
        XCTAssertEqual(map.tokens(intersecting: selected), 1..<4)
        XCTAssertEqual(map.textRange(for: 1..<4), selected)
        XCTAssertNil(map.tokens(intersecting: (body as NSString).range(of: "Smile")))
        XCTAssertNil(map.tokens(intersecting: NSRange(location: 0, length: 2)))
        XCTAssertNil(map.tokens(intersecting: NSRange(location: 0, length: 0)))
    }
    func testCrossLineSelectionAccentsEveryCoveredLineAndCueOnlyAtStart() throws {
        let body = "One brave\nwooden horse\nwent inside."
        var plan = PerformanceStylePlan(sourceBody: body, formattedBody: body, moments: [], usedAI: false)
        plan = try XCTUnwrap(plan.editing(tokens: 1..<5, treatment: .emphasize))
        plan = try XCTUnwrap(plan.editing(tokens: 1..<5, treatment: .deliveryCue, cue: "Whisper"))
        let document = ScriptDocument(plan.formattedBody)
        let styled = document.lines.map { line in
            PerformanceRanges.ranges(in: line.spokenText, tokenOffset: line.tokenRange.lowerBound, moments: plan.displayMoments(for: line))
                .map { (line.spokenText as NSString).substring(with: $0.range) }.joined()
        }
        XCTAssertEqual(styled, ["brave", "wooden horse", "went"])
        XCTAssertEqual(plan.deliveryCue(for: document.lines[0]), "Whisper")
        XCTAssertNil(plan.deliveryCue(for: document.lines[1]))
        XCTAssertTrue(plan.isValid(for: body))
    }
    func testPauseKeepsPunctuationAndWordsAndAnchorThroughReflow() throws {
        let body = "Wait here, and then walk inside."
        let original = PerformanceStylePlan(sourceBody: body, formattedBody: body, moments: [], usedAI: false)
        var plan = try XCTUnwrap(original.editing(tokens: 0..<2, treatment: .pause))
        XCTAssertEqual(plan.formattedBody, "Wait here, \nand then walk inside.")
        XCTAssertTrue(plan.pauseAfter(ScriptDocument(plan.formattedBody).lines[0]))
        XCTAssertFalse(plan.pauseAfter(ScriptDocument(plan.formattedBody).lines[1]))
        plan = try XCTUnwrap(plan.editing(tokens: 4..<6, treatment: .emphasize))
        XCTAssertEqual(plan.sourceBody, body)
        XCTAssertEqual(ScriptDocument(plan.formattedBody).tokens, ScriptDocument(body).tokens)
        XCTAssertEqual(plan.moments.last?.tokenAnchor?.range, 4..<6)
    }
    func testOldSavedPlanAndNewMetadataRoundTrip() throws {
        let old = #"{"id":"633BB6DB-F292-4F15-B8AD-39CED1CFF2A3","sourceBody":"Hello world","formattedBody":"Hello world","moments":[{"lineID":0,"phrase":"Hello","tone":"cyan","scale":"large","pauseAfter":false}],"usedAI":false}"#
        let plan = try JSONDecoder().decode(PerformanceStylePlan.self, from: Data(old.utf8))
        XCTAssertNil(plan.moments[0].tokenAnchor)
        XCTAssertNil(plan.moments[0].deliveryCue)
        let edited = try XCTUnwrap(plan.editing(tokens: 1..<2, treatment: .deliveryCue, cue: "Smile"))
        let roundTrip = try JSONDecoder().decode(PerformanceStylePlan.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(roundTrip, edited)
        XCTAssertTrue(roundTrip.isValid(for: "Hello world"))
    }
    func testInvalidSelectionCannotAlterThePlan() {
        let plan = PerformanceLayout.localPlan(for: "Hello world.")
        XCTAssertNil(plan.editing(tokens: 0..<10, treatment: .emphasize))
        XCTAssertNil(plan.editing(tokens: 1..<1, treatment: .pause))
        XCTAssertNil(plan.editing(tokens: 0..<1, treatment: .deliveryCue, cue: "   "))
    }
}
