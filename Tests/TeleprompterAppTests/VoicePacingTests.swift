import XCTest
@testable import TeleprompterApp

@MainActor final class VoicePacingTests: XCTestCase {
    private func makeModel() -> (TeleprompterModel, TranscriptCapture) {
        let capture = TranscriptCapture()
        let model = TeleprompterModel(capture: capture, defaults: nil)
        model.load(ScriptRecord(id: UUID(), title: "Speech pace test", body: """
        [Lean toward the camera.]
        Okay.
        I need you to help me with something.
        [Pause.]
        Imagine somebody has been trying to break into your Minecraft base.
        for TEN YEARS.
        They have tried everything.
        They attacked the front.
        They attacked the back.
        But they cannot get in.
        Then one morning everybody was gone.
        Outside your home stood an enormous wooden horse.
        Would you open it or leave it alone?
        """, modifiedAt: .now))
        return (model, capture)
    }
    private func say(_ count: Int, to model: TeleprompterModel, through capture: TranscriptCapture) {
        capture.onTranscript?(model.document.tokens.prefix(count).joined(separator: " "))
    }
    func testSpeechUpdatesScrollImmediatelyAndSilenceHolds() async throws {
        let (model, capture) = makeModel()
        XCTAssertEqual(model.displayedReadingLineID, 1, "Cue-only rows must never send the notch back to the first phrase")
        XCTAssertEqual(model.progress, 0)
        await model.start()
        say(4, to: model, through: capture)
        for count in [8, 12, 16, 20] {
            say(count, to: model, through: capture)
            XCTAssertEqual(model.displayedReadingLineID, model.activeLineID,
                           "A reliable phrase change must reach the reader in the same turn, without a debounce")
            XCTAssertEqual(model.snapshot(at: .now).wordIndex, model.tokenIndex)
        }
        XCTAssertEqual(model.tokenIndex, 19)
        XCTAssertEqual(model.displayedReadingLineID, model.activeLineID)
        let heldTarget = model.displayedScrollTarget
        let heldWord = model.tokenIndex
        for _ in 0..<8 { say(20, to: model, through: capture) }
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(model.displayedScrollTarget, heldTarget, "Silence and duplicate partials must never drift")
        XCTAssertEqual(model.tokenIndex, heldWord)
        say(28, to: model, through: capture)
        XCTAssertEqual(model.tokenIndex, 27, "New spoken words resume following")
        model.pause()
    }
    func testScrollAnimationHonorsReduceMotionAndPauseHasNoQueuedAdvance() async throws {
        XCTAssertNil(ReadingScrollMotion.animation(reduceMotion: true))
        XCTAssertNotNil(ReadingScrollMotion.animation(reduceMotion: false))
        let (model, capture) = makeModel()
        await model.start()
        say(4, to: model, through: capture)
        say(12, to: model, through: capture)
        model.pause()
        let target = model.displayedScrollTarget
        say(20, to: model, through: capture)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(model.displayedScrollTarget, target)
        XCTAssertEqual(model.displayedReadingLineID, model.activeLineID)
    }
    func testCountdownWarnsWithoutAdvancingTheReaderAndPauseClearsWarning() async throws {
        let (model, capture) = makeModel()
        model.timerMode = .countdown
        await model.start()
        let start = try XCTUnwrap(model.sessionStart)
        let target = model.displayedScrollTarget
        XCTAssertFalse(model.refreshPaceFeedback(at: start.addingTimeInterval(60)))
        XCTAssertTrue(model.refreshPaceFeedback(at: start.addingTimeInterval(63)))
        XCTAssertEqual(model.paceWarning, .speedUp, "A presenter who hasn't begun should still get a time warning")
        XCTAssertEqual(model.displayedScrollTarget, target)
        XCTAssertEqual(model.tokenIndex, 0)
        XCTAssertTrue(model.refreshPaceFeedback(at: start.addingTimeInterval(301)))
        XCTAssertEqual(model.paceWarning, .overtime)
        XCTAssertEqual(model.presentationTime(at: start.addingTimeInterval(301)), "-00:01")
        XCTAssertEqual(model.displayedScrollTarget, target)
        model.pause()
        XCTAssertNil(model.paceWarning)
        say(20, to: model, through: capture)
        XCTAssertEqual(model.tokenIndex, 0, "Late transcripts after Pause are ignored")
    }
    func testGettingAheadHintsSlowDownAndTimerResetUsesRemainingWords() async throws {
        let (model, capture) = makeModel()
        model.timerMode = .countdown
        await model.start()
        for count in stride(from: 4, through: 36, by: 4) { say(count, to: model, through: capture) }
        let start = try XCTUnwrap(model.sessionStart)
        XCTAssertFalse(model.refreshPaceFeedback(at: start.addingTimeInterval(30)))
        XCTAssertTrue(model.refreshPaceFeedback(at: start.addingTimeInterval(33)))
        XCTAssertEqual(model.paceWarning, .slowDown)
        let position = model.tokenIndex
        model.resetTimer()
        XCTAssertNil(model.paceWarning)
        let reset = try XCTUnwrap(model.sessionStart)
        XCTAssertEqual(model.paceHint(at: reset.addingTimeInterval(60)), .speedUp,
                       "After resetting mid-script, pacing measures the remaining words")
        XCTAssertEqual(model.tokenIndex, position)
        model.showPaceHints = false
        model.refreshPaceFeedback(at: reset.addingTimeInterval(100))
        XCTAssertNil(model.paceWarning)
        model.pause()
    }
    func testTimerDirectionAndDurationNeverChangeSpeechPosition() async throws {
        let (model, capture) = makeModel()
        await model.start()
        say(6, to: model, through: capture)
        let position = model.tokenIndex
        let target = model.displayedScrollTarget
        model.timerMode = .countdown
        model.countdownMinutes = 1
        model.refreshPaceFeedback(at: try XCTUnwrap(model.sessionStart).addingTimeInterval(90))
        XCTAssertEqual(model.paceWarning, .overtime)
        model.timerMode = .countUp
        model.refreshPaceFeedback(at: .now)
        XCTAssertNil(model.paceWarning)
        XCTAssertEqual(model.tokenIndex, position)
        XCTAssertEqual(model.displayedScrollTarget, target)
        model.pause()
    }
}

@MainActor private final class TranscriptCapture: SpeechCapturing {
    var state: SpeechFollower.State = .idle
    var onTranscript: ((String) -> Void)?
    var onUnexpectedStop: (() -> Void)?
    func start() async { state = .listening }
    func pause() { state = .paused }
    func stop() { state = .idle }
}
