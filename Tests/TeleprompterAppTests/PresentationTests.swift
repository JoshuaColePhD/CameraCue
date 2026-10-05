import XCTest
import SwiftUI
@testable import TeleprompterApp
import TeleprompterCore

@MainActor final class PresentationTests: XCTestCase {
    private func script(_ body: String = "One little horse.\nTwo mighty walls.") -> ScriptRecord {
        ScriptRecord(id: UUID(), title: "Test", body: body, modifiedAt: .now)
    }
    func testEditsAndAIResultsWaitThroughPauseResumeUntilRestart() async {
        let model = TeleprompterModel(defaults: nil)
        model.mode = .manual
        var source = script()
        model.load(source)
        await model.start()
        model.move(lines: 1)
        let position = model.tokenIndex
        source.performance = PerformanceLayout.localPlan(for: source.body)
        model.load(source)
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.performance)
        XCTAssertEqual(model.tokenIndex, position)
        model.pause()
        source.body = "A different script for the next take."
        source.performance = nil
        model.load(source)
        XCTAssertTrue(model.hasPendingScriptChanges)
        await model.start()
        XCTAssertEqual(model.tokenIndex, position)
        XCTAssertNotEqual(model.document.source, source.body)
        model.reset()
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.hasPendingScriptChanges)
        XCTAssertEqual(model.document.tokens, ScriptDocument(source.body).tokens)
        XCTAssertEqual(model.tokenIndex, 0)
        XCTAssertNil(model.sessionStart)
    }
    func testSwitchingScriptStopsCaptureAndClearsTheTake() async {
        let capture = FakeCapture()
        let model = TeleprompterModel(capture: capture, defaults: nil)
        model.load(script())
        await model.start()
        XCTAssertTrue(model.isRunning)
        model.load(script("A new script."))
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(capture.state, .idle)
        XCTAssertNil(model.sessionStart)
    }
    func testDuplicateStartsAndLateStartupCannotRestartStoppedPresentation() async {
        let capture = FakeCapture()
        capture.delayed = true
        let model = TeleprompterModel(capture: capture, defaults: nil)
        model.load(script())
        let pending = Task { await model.start() }
        while capture.continuation == nil { await Task.yield() }
        await model.start()
        XCTAssertEqual(capture.starts, 1)
        model.stop()
        capture.complete()
        await pending.value
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.isStarting)
        XCTAssertNil(model.sessionStart)
    }
    func testInterruptionPausesTimerAndKeepsPosition() async {
        let capture = FakeCapture()
        let model = TeleprompterModel(capture: capture, defaults: nil)
        model.load(script())
        await model.start()
        model.move(lines: 1)
        let position = model.tokenIndex
        capture.onUnexpectedStop?()
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.tokenIndex, position)
        XCTAssertEqual(model.presentationTime(at: .now), model.presentationTime(at: .now.addingTimeInterval(60)))
    }
    func testPermissionCompletionAfterStopDoesNotOpenMicrophone() async {
        let permissions = DelayedPermissions()
        var captures = 0
        let follower = SpeechFollower(permissions: permissions, captureOverride: { captures += 1 })
        let pending = Task { await follower.start() }
        while permissions.continuation == nil { await Task.yield() }
        await follower.start()
        XCTAssertEqual(permissions.requests, 1)
        follower.stop()
        permissions.continuation?.resume(returning: true)
        await pending.value
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(follower.state, .idle)
        XCTAssertFalse(follower.isAuthorizing)
    }
    func testPermissionDenialAndCaptureFailureHaveExplicitStates() async {
        let denied = SpeechFollower(permissions: ImmediatePermissions(allowed: false), captureOverride: { XCTFail("Must not capture") })
        await denied.start()
        XCTAssertEqual(denied.state, .denied)
        let failed = SpeechFollower(permissions: ImmediatePermissions(allowed: true), captureOverride: { throw NSError(domain: "Test", code: 1) })
        await failed.start()
        XCTAssertEqual(failed.state, .error)
    }
    func testShapeExcludesTransparentCornersAtEveryTransitionSize() async {
        for progress in [0.0, 0.25, 0.5, 0.75, 1] {
            let rect = CGRect(x: 0, y: 0, width: 366 + 194 * progress, height: 34 + 230 * progress)
            let path = NotchShape(expansion: progress).path(in: rect)
            XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
            XCTAssertFalse(path.contains(CGPoint(x: 1, y: rect.maxY - 1)))
            XCTAssertFalse(path.contains(CGPoint(x: rect.maxX + 1, y: 10)))
        }
    }
}

@MainActor private final class FakeCapture: SpeechCapturing {
    var state: SpeechFollower.State = .idle
    var onTranscript: ((String) -> Void)?
    var onUnexpectedStop: (() -> Void)?
    var delayed = false
    var starts = 0
    var continuation: CheckedContinuation<Void, Never>?
    func start() async {
        starts += 1; state = .requesting
        if delayed { await withCheckedContinuation { continuation = $0 } }
        state = .listening
    }
    func complete() { continuation?.resume(); continuation = nil }
    func pause() { state = .paused }
    func stop() { state = .idle }
}
@MainActor private final class DelayedPermissions: SpeechPermissionProviding {
    let needsPrompt = false
    let summary = "Test"
    var requests = 0
    var continuation: CheckedContinuation<Bool, Never>?
    func authorize(whileCurrent: () -> Bool) async -> Bool {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }
}
@MainActor private struct ImmediatePermissions: SpeechPermissionProviding {
    let allowed: Bool
    let needsPrompt = false
    let summary = "Test"
    func authorize(whileCurrent: () -> Bool) async -> Bool { allowed }
}
