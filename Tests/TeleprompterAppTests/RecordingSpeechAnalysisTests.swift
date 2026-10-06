import XCTest
import TeleprompterCore
@testable import TeleprompterApp

final class RecordingSpeechAnalysisTests: XCTestCase {
    @MainActor func testPilotResourceIsValidAndDisabledByDefault() throws {
        let model = try XCTUnwrap(LearnedTrackingModel.available)
        XCTAssertTrue(model.isValid); XCTAssertNotNil(model.maximumScriptTokens)
        XCTAssertFalse(TeleprompterModel(defaults: nil).learnedTrackingEnabled)
    }
    func testCaptureResumesKeepMediaTimelineAndExcludeCountIn() throws {
        var collector = RecordingSpeechCollector(); collector.begin(at: 100)
        let before = SpeechObservation(engine: .legacy, text: "count", audioStart: 0, audioEnd: 1, deliveredAt: 1, isFinal: true,
                                       words: [TimedSpeechWord(text: "count", start: 0, end: 1)], sourceUptimeOrigin: 98)
        collector.consume(before); XCTAssertNil(collector.snapshot(script: nil))
        let resume = SpeechObservation(engine: .analyzer, text: "hello", audioStart: 0, audioEnd: 1, deliveredAt: 1, isFinal: true,
                                       words: [TimedSpeechWord(text: "hello", start: 0, end: 1)], sourceUptimeOrigin: 120)
        collector.consume(resume)
        let word = try XCTUnwrap(collector.snapshot(script: nil)?.words.first)
        XCTAssertEqual(word.start, 20); XCTAssertEqual(word.end, 21)
    }
    func testSidecarRejectsInvalidTimesAndLeavesVideoUntouched() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("take.mp4"), original = Data([1, 2, 3])
        try original.write(to: video)
        var analysis = RecordingSpeechAnalysis(videoFilename: "", analyzedAt: .now, engine: .legacy,
                                               words: [TimedSpeechWord(text: "hello", start: 0, end: 1)], script: "hello", containsProvisionalWords: false)
        try RecordingSpeechAnalysisStore.write(analysis, video: video)
        XCTAssertEqual(try RecordingSpeechAnalysisStore.read(video: video)?.videoFilename, "take.mp4")
        analysis.words[0].end = -.infinity
        XCTAssertThrowsError(try RecordingSpeechAnalysisStore.write(analysis, video: video))
        XCTAssertEqual(try Data(contentsOf: video), original)
        XCTAssertEqual(try RecordingSpeechAnalysisStore.read(video: video)?.words.count, 1)
    }
}
