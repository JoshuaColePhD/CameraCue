import XCTest
import AppKit
import QuartzCore
@testable import TeleprompterApp

@MainActor final class NotchRecordTests: XCTestCase {
    func testExpandedRecordingLabelHasSeparateStopTargetAndReducedMotion() throws {
        _ = NSApplication.shared
        let button = NotchRecordControl(frame: CGRect(x: 0, y: 0, width: 86, height: 28))
        button.showsRecordingLabel = true
        button.configure(phase: .running, reduceMotion: false)
        button.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(button.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.stringValue, "Recording")
        XCTAssertFalse(label.isHidden)
        XCTAssertLessThan(button.recordLight.frame.maxX, label.frame.minX)
        XCTAssertNotNil(label.layer?.animation(forKey: "recordPulse"))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 14),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        button.mouseDown(with: event) // Status text must not enter the button's click tracking loop.
        button.configure(phase: .running, reduceMotion: true)
        XCTAssertNil(label.layer?.animation(forKey: "recordPulse"))
        XCTAssertFalse(label.isHidden)
        button.configure(phase: .paused, reduceMotion: true)
        XCTAssertTrue(label.isHidden)
    }
    func testRecordControlShowsCorrectStateAndGentlePulseWithoutMoving() throws {
        _ = NSApplication.shared
        let button = NotchRecordControl(frame: CGRect(x: 377, y: 3, width: 52, height: 28))
        let frame = button.frame
        for (phase, title) in [(PresentationPhase.ready, "Record"), (.starting, "Cancel"), (.countIn, "Cancel"),
                               (.running, ""), (.paused, "Resume"), (.finished, "Record")] {
            button.configure(phase: phase, reduceMotion: false)
            button.layoutSubtreeIfNeeded()
            XCTAssertEqual(button.attributedTitle.string, title)
            XCTAssertLessThan(button.attributedTitle.size().width, frame.width)
            XCTAssertEqual(button.frame, frame)
            XCTAssertEqual(button.recordLight.isHidden, phase != .running)
            XCTAssertTrue(button.toolTip?.contains("QuickTime") == true)
            if phase == .running {
                let pulse = try XCTUnwrap(button.recordLight.animation(forKey: "recordPulse") as? CAKeyframeAnimation)
                XCTAssertEqual(pulse.duration, 2.6)
                XCTAssertEqual(pulse.repeatCount, .infinity)
                XCTAssertEqual(pulse.values?.compactMap { ($0 as? NSNumber)?.doubleValue }, [1, 0.55, 1])
                XCTAssertEqual(button.accessibilityLabel(), "Stop prompting")
                XCTAssertEqual(button.recordLight.backgroundColor, NSColor(CuePalette.coral).cgColor)
                XCTAssertEqual(button.recordLight.frame.size, CGSize(width: 14, height: 14))
                XCTAssertEqual(button.recordLight.frame.midX, button.bounds.midX)
                XCTAssertEqual(button.recordLight.frame.midY, button.bounds.midY)
                XCTAssertEqual(button.recordLight.cornerRadius, 2,
                               "The active control must read as a stop square, not a recording dot")
            } else {
                XCTAssertNil(button.recordLight.animation(forKey: "recordPulse"))
            }
        }
    }
    func testPulseSurvivesRefreshAndStopsForReduceMotionOrPause() throws {
        _ = NSApplication.shared
        let button = NotchRecordControl()
        button.configure(phase: .running, reduceMotion: false)
        let pulse = try XCTUnwrap(button.recordLight.animation(forKey: "recordPulse")?.copy() as? CAAnimation)
        pulse.beginTime = 42
        button.recordLight.add(pulse, forKey: "recordPulse")
        for _ in 0..<10 { button.configure(phase: .running, reduceMotion: false) }
        XCTAssertEqual(button.recordLight.animation(forKey: "recordPulse")?.beginTime, 42,
                       "Speech and timer refreshes cannot restart the pulse")
        button.configure(phase: .running, reduceMotion: true)
        XCTAssertNil(button.recordLight.animation(forKey: "recordPulse"))
        XCTAssertFalse(button.recordLight.isHidden, "Reduce Motion retains a steady coral indicator")
        button.configure(phase: .running, reduceMotion: false)
        XCTAssertNotNil(button.recordLight.animation(forKey: "recordPulse"))
        button.configure(phase: .paused, reduceMotion: false)
        XCTAssertTrue(button.recordLight.isHidden)
        XCTAssertNil(button.recordLight.animation(forKey: "recordPulse"))
        button.allowsInteraction = false
        XCTAssertFalse(button.accessibilityPerformPress(), "Live preview cannot start or finish a take")
    }
    func testRecordStartsAndLightFinishesCaptureWithFrozenSummaryThenStartsNewTake() async throws {
        let capture = RecordCapture()
        var date = Date(timeIntervalSince1970: 1000)
        let model = TeleprompterModel(capture: capture, defaults: nil, now: { date })
        model.load(ScriptRecord(id: UUID(), title: "Test", body: "One little horse.\nTwo tall walls.", modifiedAt: date))
        await model.performNotchRecordAction()
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(capture.state, .listening)
        date += 12
        await model.performNotchRecordAction()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(capture.state, .idle)
        XCTAssertFalse(model.displayIsLocked)
        XCTAssertEqual(model.summary?.activeDuration, 12)
        date += 10
        XCTAssertEqual(model.presentationTime(at: date), "00:12")
        await model.performNotchRecordAction()
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(capture.starts, 2)
        XCTAssertEqual(model.presentationTime(at: date), "00:00")
        XCTAssertEqual(model.latestSummary?.activeDuration, 12)
        model.pause()
        XCTAssertEqual(model.phase, .paused)
        await model.performNotchRecordAction()
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(capture.starts, 3)
        model.finish()
    }
    func testCountInCanBeCancelledWithoutFlashingActiveLightOrStartingTimer() async {
        let model = TeleprompterModel(defaults: nil)
        model.mode = .manual; model.useCountIn = true
        model.load(ScriptRecord(id: UUID(), title: "Test", body: "One little horse.", modifiedAt: .now))
        let start = Task { await model.performNotchRecordAction() }
        while model.countInSeconds == nil { await Task.yield() }
        XCTAssertEqual(model.phase, .countIn)
        await model.performNotchRecordAction()
        await start.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.summary)
        XCTAssertFalse(model.displayIsLocked)
        XCTAssertEqual(model.presentationTime(at: .now), "00:00")
    }
    func testCancelDuringStartupRejectsLatePermissionCompletion() async {
        let permissions = RecordPermissions()
        var captures = 0
        let follower = SpeechFollower(permissions: permissions, captureOverride: { captures += 1 })
        let model = TeleprompterModel(capture: follower, defaults: nil)
        model.load(ScriptRecord(id: UUID(), title: "Test", body: "One little horse.", modifiedAt: .now))
        let pending = Task { await model.performNotchRecordAction() }
        while permissions.continuation == nil { await Task.yield() }
        XCTAssertEqual(model.phase, .starting)
        await model.performNotchRecordAction()
        permissions.continuation?.resume(returning: true)
        await pending.value
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.sessionStart)
        XCTAssertFalse(model.displayIsLocked)
    }
}

@MainActor private final class RecordPermissions: SpeechPermissionProviding {
    let needsPrompt = false
    let summary = "Test"
    var continuation: CheckedContinuation<Bool, Never>?
    func authorize(whileCurrent: () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor private final class RecordCapture: SpeechCapturing {
    var state: SpeechFollower.State = .idle
    var onTranscript: ((String) -> Void)?
    var onUnexpectedStop: (() -> Void)?
    var starts = 0
    func start() async { starts += 1; state = .listening }
    func pause() { state = .paused }
    func stop() { state = .idle }
}
