import XCTest
@testable import TeleprompterCore

final class ScriptAlignerTests: XCTestCase {
    func testAnnotationsAndNumbersAreIgnoredOrNormalized() {
        let document = ScriptDocument("[Pause.]\nTen. Years.\n[Point at camera.]\nThey're gone.")
        XCTAssertEqual(document.tokens, ["ten", "years", "they", "are", "gone"])
        XCTAssertEqual(TranscriptNormalizer.tokens("10 years, they are gone"), document.tokens)
        XCTAssertEqual(document.lines[0].tokenRange.count, 0)
    }

    func testExactReadingAndMissingWord() {
        let text = "The Greeks built a giant wooden horse."
        let exact = ScriptAligner(script: ScriptDocument(text)).align(text)
        XCTAssertEqual(exact.confidence, .high)
        XCTAssertEqual(exact.tokenIndex, 6)
        let missing = ScriptAligner(script: ScriptDocument(text)).align("The Greeks built a wooden horse")
        XCTAssertNotEqual(missing.confidence, .low)
        XCTAssertEqual(missing.tokenIndex, 6)
    }

    func testFillerAndContraction() {
        let script = ScriptDocument("They are completely gone. The Greeks built a giant wooden horse.")
        let aligner = ScriptAligner(script: script)
        XCTAssertEqual(aligner.align("They're completely gone").tokenIndex, 3)
        let result = aligner.align("The Greeks basically built this giant wooden horse")
        XCTAssertNotEqual(result.confidence, .low)
        XCTAssertEqual(result.tokenIndex, script.tokens.count - 1)
    }

    func testAdLibHoldsAndReacquires() {
        let script = ScriptDocument("Would you bring the horse inside? The Trojans did.")
        let aligner = ScriptAligner(script: script)
        XCTAssertEqual(aligner.align("Would you bring the horse inside").tokenIndex, 5)
        let before = aligner.position
        let adLib = aligner.align("Be honest I know some of you would")
        XCTAssertEqual(adLib.tokenIndex, before)
        XCTAssertEqual(adLib.confidence, .low)
        XCTAssertEqual(aligner.align("The Trojans did").tokenIndex, script.tokens.count - 1)
    }

    func testRepeatedPhrasePrefersNearbyOccurrence() {
        let script = ScriptDocument("The Greeks arrived. The Greeks waited. The Greeks built a horse. The Greeks returned.")
        let aligner = ScriptAligner(script: script)
        aligner.reset(to: 3)
        let result = aligner.align("The Greeks waited")
        XCTAssertEqual(result.tokenIndex, 5)
    }

    func testSilenceDoesNotAdvanceWithoutTranscript() {
        let aligner = ScriptAligner(script: ScriptDocument("Would you bring the horse inside?"))
        _ = aligner.align("Would you bring the horse")
        let before = aligner.position
        // There is deliberately no timer or silence update on the aligner.
        XCTAssertEqual(aligner.position, before)
    }

    func testSkipForwardNeedsRepeatedEvidence() {
        let script = ScriptDocument("Alpha bravo charlie delta echo foxtrot golf hotel india juliet. One two three four five six seven eight nine ten. The wooden horse came through the gate.")
        let aligner = ScriptAligner(script: script)
        _ = aligner.align("Alpha bravo charlie")
        for _ in 0..<4 { _ = aligner.align("The wooden horse came through the gate") }
        XCTAssertGreaterThan(aligner.position, 18)
    }
    func testDuplicateMissesCannotUnlockDistantRecovery() {
        let source = "Alpha bravo charlie. " + Array(repeating: "interlude", count: 65).joined(separator: " ") + " The wooden horse entered through the gate."
        let aligner = ScriptAligner(script: ScriptDocument(source))
        _ = aligner.align("alpha bravo charlie")
        _ = aligner.align("the wooden horse")
        let misses = aligner.misses
        for _ in 0..<20 { _ = aligner.align("the wooden horse") }
        XCTAssertEqual(aligner.misses, misses)
        XCTAssertEqual(aligner.position, 2)
        _ = aligner.align("the wooden horse entered")
        let recovered = aligner.align("the wooden horse entered through")
        XCTAssertNotEqual(recovered.confidence, .low)
        XCTAssertGreaterThan(recovered.tokenIndex, 65)
    }

    func testShortRepeatedPhraseCannotCauseLargeJump() {
        let aligner = ScriptAligner(script: ScriptDocument("We begin here. A few words establish the opening. We choose the moon in this decade."))
        aligner.reset(to: 2)
        let update = aligner.align("the moon in")
        XCTAssertEqual(update.tokenIndex, 2)
        XCTAssertEqual(update.confidence, .low)
    }

    func testStrongBackwardRestartUsesRawMatchQuality() {
        let source = "The wooden horse entered through the gate. " + Array(repeating: "interlude", count: 14).joined(separator: " ") + " We begin the closing remarks now."
        let aligner = ScriptAligner(script: ScriptDocument(source))
        aligner.reset(to: 20)
        let update = aligner.align("the wooden horse entered through the gate")
        XCTAssertEqual(update.tokenIndex, 6)
        XCTAssertNotEqual(update.confidence, .low)
    }

}
