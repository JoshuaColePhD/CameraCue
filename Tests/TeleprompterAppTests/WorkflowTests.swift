import XCTest
@testable import TeleprompterApp

@MainActor final class WorkflowTests: XCTestCase {
    func model() -> TeleprompterModel {
        let model = TeleprompterModel(defaults: nil)
        model.mode = .manual
        model.load(ScriptRecord(id: UUID(), title: "Practice", body: "One phrase.\n[Pause.]\n\nAnother phrase.\nA final phrase.", modifiedAt: .now))
        return model
    }
    func testRecoverySkipsCuesAndKeepsTimer() async {
        let model = model()
        model.move(lines: 1)
        XCTAssertEqual(model.activeLineID, 3)
        model.move(lines: -1)
        XCTAssertEqual(model.activeLineID, 0)
        await model.start()
        model.selectPhrase(4)
        XCTAssertEqual(model.activeLineID, 0, "Picking a phrase is only allowed while paused")
        model.pause()
        let time = model.presentationTime(at: .now)
        model.selectPhrase(4)
        XCTAssertEqual(model.activeLineID, 4)
        XCTAssertEqual(model.presentationTime(at: .now.addingTimeInterval(60)), time)
        model.reset()
        XCTAssertEqual(model.activeLineID, 0)
        XCTAssertNil(model.sessionStart)
    }
    func testTimerAdjustmentsPreservePositionAndElapsedTime() async {
        let model = model()
        await model.start()
        model.move(lines: 1)
        let start = try! XCTUnwrap(model.sessionStart)
        let future = start.addingTimeInterval(65.2)
        XCTAssertEqual(model.presentationTime(at: future), "01:05")
        model.timerMode = .countdown; model.countdownMinutes = 1
        XCTAssertEqual(model.presentationTime(at: future), "-00:05")
        model.countdownMinutes = 3
        XCTAssertEqual(model.presentationTime(at: future), "01:55")
        XCTAssertEqual(model.activeLineID, 3)
        model.pause(); model.resetTimer()
        XCTAssertEqual(model.activeLineID, 3)
        XCTAssertEqual(model.presentationTime(at: .now), "03:00")
    }
    func testCancelledCountInNeverStartsTheClock() async {
        let model = model(); model.useCountIn = true
        let start = Task { await model.start() }
        while model.countInSeconds == nil { await Task.yield() }
        XCTAssertNil(model.sessionStart)
        XCTAssertFalse(model.isRunning)
        start.cancel()
        await start.value
        XCTAssertFalse(model.isStarting)
        XCTAssertNil(model.countInSeconds)
        XCTAssertNil(model.sessionStart)
    }
    func testCountInStartsOnlyAfterThreeSeconds() async {
        let model = model(); model.useCountIn = true
        let before = Date()
        await model.start()
        XCTAssertTrue(model.isRunning)
        XCTAssertGreaterThanOrEqual(model.sessionStart?.timeIntervalSince(before) ?? 0, 2.9)
        XCTAssertEqual(model.presentationTime(at: .now), "00:00")
        model.pause()
        let resumed = Date()
        await model.start()
        XCTAssertLessThan(Date().timeIntervalSince(resumed), 0.5, "Resume skips the initial count-in")
        model.pause()
    }
}
