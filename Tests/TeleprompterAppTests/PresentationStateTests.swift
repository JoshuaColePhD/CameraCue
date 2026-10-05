import XCTest
import AppKit
import TeleprompterCore
@testable import TeleprompterApp

@MainActor final class PresentationStateTests: XCTestCase {
    private var date = Date(timeIntervalSince1970: 1000)
    private func model(_ capture: StateCapture? = nil) -> TeleprompterModel {
        let value = TeleprompterModel(capture: capture ?? StateCapture(), defaults: nil, now: { [unowned self] in self.date })
        value.load(ScriptRecord(id: UUID(), title: "Test", body: "One little horse.\nTwo mighty walls.\nThree brave soldiers.", modifiedAt: date))
        return value
    }
    func testFinishFreezesTotalDurationAndTimerSegmentSeparately() async throws {
        let capture = StateCapture(), value = model(capture)
        value.timerMode = .countdown; value.countdownMinutes = 1
        XCTAssertEqual(value.phase, .ready)
        await value.start()
        XCTAssertEqual(value.phase, .running); XCTAssertTrue(value.displayIsLocked)
        date += 30; value.resetTimer()
        date += 20; value.pause()
        XCTAssertEqual(value.phase, .paused); XCTAssertTrue(value.displayIsLocked)
        date += 50; await value.start(); date += 50
        value.finish()
        let summary = try XCTUnwrap(value.summary)
        XCTAssertEqual(summary.activeDuration, 100)
        XCTAssertEqual(summary.timerDuration, 70)
        XCTAssertTrue(summary.timerWasReset)
        XCTAssertEqual(summary.comparison, "Last timer segment: 0:10 over target")
        XCTAssertEqual(value.phase, .finished); XCTAssertFalse(value.displayIsLocked)
        XCTAssertEqual(capture.state, .idle)
        XCTAssertEqual(value.presentationTime(at: date), "-00:10")
        date += 100
        XCTAssertEqual(value.presentationTime(at: date), "-00:10")
        let starts = capture.starts
        await value.start()
        XCTAssertEqual(value.phase, .ready)
        XCTAssertEqual(capture.starts, starts, "Practice again resets without starting capture")
        XCTAssertEqual(value.latestSummary, summary)
    }
    func testEndOfScriptDoesNotFinishAndModeChangesRequirePause() async {
        let value = model()
        await value.start()
        value.move(lines: 10)
        date += 90
        XCTAssertEqual(value.phase, .running)
        XCTAssertNil(value.summary)
        value.mode = .manual
        XCTAssertEqual(value.mode, .voice)
        value.pause(); value.mode = .manual
        XCTAssertEqual(value.mode, .manual)
        XCTAssertTrue(value.displayIsLocked)
        await value.start(); value.finish()
        XCTAssertEqual(value.summary?.activeDuration, 90)
    }
    func testDisplayDisconnectAndSleepPauseKeepReadingPositionUntilExplicitResume() async {
        let value = model()
        await value.start(); date += 12; value.move(lines: 1)
        let position = value.tokenIndex
        value.pauseForDisplayChange()
        XCTAssertEqual(value.phase, .paused)
        XCTAssertEqual(value.tokenIndex, position)
        XCTAssertTrue(value.displayIsLocked)
        XCTAssertEqual(value.presentationTime(at: date.addingTimeInterval(60)), "00:12")
        XCTAssertNotNil(value.snapshot(at: date).problem)
        await value.start()
        XCTAssertEqual(value.tokenIndex, position)
        XCTAssertNil(value.snapshot(at: date).problem)
        value.pause() // same path used for sleep
        XCTAssertEqual(value.phase, .paused)
    }
    func testRecoveryTakesPriorityOverPacingAndHoldsReliablePosition() async {
        let capture = StateCapture(), value = model(capture)
        value.timerMode = .countdown; value.countdownMinutes = 1
        await value.start()
        capture.onTranscript?("one little horse")
        XCTAssertEqual(value.snapshot(at: date).status, "Following")
        let position = value.tokenIndex
        date += 25; value.refreshPaceFeedback(at: date)
        date += 4; value.refreshPaceFeedback(at: date)
        capture.onTranscript?("purple submarine")
        date += 3; capture.onTranscript?("purple submarine beneath a rainbow")
        let snapshot = value.snapshot(at: date)
        XCTAssertTrue(snapshot.recovering); XCTAssertNil(snapshot.warning)
        XCTAssertEqual(value.tokenIndex, position)
        XCTAssertEqual(snapshot.lineID, value.displayedReadingLineID)
        XCTAssertEqual(snapshot.timerText, value.presentationTime(at: date))
        capture.onTranscript?("two mighty walls")
        XCTAssertEqual(value.snapshot(at: date).status, "Following")
        XCTAssertFalse(value.snapshot(at: date).recovering)
        value.finish()
    }
    func testDisconnectDuringCountInRequiresResumeOrFinish() async {
        let value = model(); value.mode = .manual; value.useCountIn = true
        let starting = Task { await value.start() }
        while value.countInSeconds == nil { await Task.yield() }
        value.pauseForDisplayChange(); await starting.value
        XCTAssertEqual(value.phase, .paused)
        XCTAssertTrue(value.displayIsLocked)
        XCTAssertTrue(value.snapshot(at: date).canFinish)
        value.finish()
        XCTAssertEqual(value.phase, .finished)
        XCTAssertEqual(value.summary?.activeDuration, 0)
        XCTAssertFalse(value.displayIsLocked)
    }
    func testCancelledCountInReleasesPlacementWithoutSummary() async {
        let value = model(); value.mode = .manual; value.useCountIn = true
        let starting = Task { await value.start() }
        while value.countInSeconds == nil { await Task.yield() }
        XCTAssertTrue(value.displayIsLocked)
        value.pause(); await starting.value
        XCTAssertEqual(value.phase, .ready); XCTAssertFalse(value.displayIsLocked)
        XCTAssertNil(value.summary)
    }
}

@MainActor private final class StateCapture: SpeechCapturing {
    var state: SpeechFollower.State = .idle
    var onTranscript: ((String) -> Void)?
    var onUnexpectedStop: (() -> Void)?
    var starts = 0
    func start() async { starts += 1; state = .listening }
    func pause() { state = .paused }
    func stop() { state = .idle }
}
