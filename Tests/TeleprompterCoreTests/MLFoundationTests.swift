import XCTest
@testable import TeleprompterCore

final class MLFoundationTests: XCTestCase {
    func testWordErrorCountsIncludeMissingAndExtraWords() {
        XCTAssertEqual(WordErrorCounts.compare(reference: ["one", "two"], recognized: []).deletions, 2)
        XCTAssertEqual(WordErrorCounts.compare(reference: [], recognized: ["one"]).insertions, 1)
        let result = WordErrorCounts.compare(reference: ["the", "horse", "arrived"], recognized: ["the", "house", "arrived", "today"])
        XCTAssertEqual(result.substitutions, 1); XCTAssertEqual(result.insertions, 1)
    }
    func testVolatileRevisionsReplaceWordsAndCannotOverwriteFinalizedAudio() {
        func event(_ text: String, _ final: Bool) -> SpeechObservation {
            SpeechObservation(engine: .analyzer, text: text, audioStart: 0, audioEnd: 1, deliveredAt: 2, isFinal: final,
                              words: [TimedSpeechWord(text: text, start: 0, end: 1)])
        }
        var ledger = SpeechTranscriptLedger()
        ledger.consume(event("one house", false)); ledger.consume(event("one horse", true)); ledger.consume(event("one house", false))
        XCTAssertEqual(ledger.text, "one horse"); XCTAssertEqual(ledger.spans.count, 1)
    }
    func testOfflineMetricsNeverClaimLiveHighlightLatency() {
        let words = [TimedSpeechWord(text: "one", start: 0, end: 1), TimedSpeechWord(text: "horse", start: 1, end: 2)]
        let event = SpeechObservation(engine: .legacy, text: "one horse", audioStart: 0, audioEnd: 2, deliveredAt: 0.5, isFinal: true, words: words)
        let metric = AudioTrackingMetrics.measure(script: "one horse", reference: words, observations: [event], realtime: false)
        XCTAssertNil(metric.highlightAgeP95); XCTAssertNil(metric.recognizerDeliveryP95)
        XCTAssertEqual(metric.withinTwoTokens, 1)
    }
    func testPaceCalibrationDoesNotLearnSkippedWordsOrPausedTime() {
        var tracker = PersonalPaceTracker()
        tracker.observe(position: 0, activeElapsed: 0, reliable: true)
        for step in 1...20 { tracker.observe(position: step * 3, activeElapsed: Double(step) * 1.5, reliable: true) }
        let before = tracker.reliableWords
        tracker.observe(position: 200, activeElapsed: 31, reliable: true)
        XCTAssertEqual(tracker.reliableWords, before)
        tracker.resetAnchor()
        tracker.observe(position: 200, activeElapsed: 31, reliable: true)
        tracker.observe(position: 203, activeElapsed: 32.5, reliable: true)
        var profile = PersonalPaceProfile()
        profile.record(PersonalPaceSample(words: 60, activeSeconds: 30, recordedAt: .distantPast))
        let estimate = tracker.estimate(remainingWords: 60, profile: profile)
        XCTAssertEqual(estimate?.effectiveWordsPerMinute ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(estimate?.remainingSeconds ?? 0, 30, accuracy: 0.01)
    }
    func testCoachingFindsPausesAndRepeatedPhrasesWithSeekTimes() {
        let words = [TimedSpeechWord(text: "one", start: 0, end: 0.5), TimedSpeechWord(text: "little", start: 0.5, end: 1), TimedSpeechWord(text: "horse", start: 1, end: 1.5),
                     TimedSpeechWord(text: "one", start: 5, end: 5.5), TimedSpeechWord(text: "little", start: 5.5, end: 6), TimedSpeechWord(text: "horse", start: 6, end: 6.5)]
        let report = TakeCoachingReport.analyze(words: words, script: nil)
        XCTAssertTrue(report.findings.contains { $0.kind == .pause && $0.start == 1.5 && $0.end == 5 })
        XCTAssertTrue(report.findings.contains { $0.kind == .repetition && $0.start == 5 })
    }
    func testLearnedModelRejectsSpeakerLeakageAndKeepsItsTrainingScope() {
        var model = AlignmentDecisionModel(version: "test", featureNames: AlignmentCandidate.featureNames,
            coefficients: Array(repeating: Array(repeating: 0, count: 10), count: 3), trainingSpeakers: ["train"],
            validationSpeakers: ["validation"], heldOutSpeakers: ["test"], trainingRows: 50, sourceCorpus: "synthetic", holdThreshold: 0.8, maximumScriptTokens: 40)
        XCTAssertTrue(model.isValid); XCTAssertTrue(model.applies(to: 40)); XCTAssertFalse(model.applies(to: 41))
        let script = ScriptDocument(Array(repeating: "hello world", count: 30).joined(separator: " "))
        let baseline = ScriptAligner(script: script), scoped = ScriptAligner(script: script, decisionModel: model)
        XCTAssertEqual(baseline.align("hello world").tokenIndex, scoped.align("hello world").tokenIndex)
        XCTAssertNil(scoped.lastPrediction)
        model = AlignmentDecisionModel(version: "test", featureNames: AlignmentCandidate.featureNames,
            coefficients: Array(repeating: Array(repeating: 0, count: 10), count: 3), trainingSpeakers: ["same"],
            validationSpeakers: [], heldOutSpeakers: ["same"], trainingRows: 50, sourceCorpus: "synthetic", holdThreshold: 0.8)
        XCTAssertFalse(model.isValid)
    }

    func testSavedPaceProfileDropsInvalidSamplesBeforeRenderingRates() throws {
        let bytes = Data(#"{"samples":[{"words":60,"activeSeconds":-1,"recordedAt":0},{"words":60,"activeSeconds":30,"recordedAt":0}]}"#.utf8)
        let profile = try JSONDecoder().decode(PersonalPaceProfile.self, from: bytes)
        XCTAssertEqual(profile.samples.count, 1); XCTAssertEqual(profile.usualWordsPerMinute, 120)
    }

    func testCorpusIDsCannotEscapeTheTraceOutputDirectory() throws {
        let bytes = Data(#"{"version":"test","clips":[{"id":"../escape","speakerID":"speaker","split":"train","audioPath":"audio.wav","script":"hello","referenceWords":[{"text":"hello","start":0,"end":1,"timingSource":"forcedAlignment"}],"license":"CC BY 4.0","sourceURL":"https://example.org","duration":1,"isPublic":true}]}"#.utf8)
        let manifest = try JSONDecoder().decode(SpeechCorpusManifest.self, from: bytes)
        XCTAssertThrowsError(try manifest.validate())
    }

    func testPauseLearningExcludesStoppedTimeAndEstimatedSegments() throws {
        var tracker = PersonalPaceTracker()
        tracker.observe(position: 0, activeElapsed: 0, reliable: true)
        for step in 1...20 { tracker.observe(position: step * 3, activeElapsed: Double(step) * 1.5, reliable: true) }
        tracker.observePauseTimings([TimedSpeechWord(text: "hello", start: 0, end: 1), TimedSpeechWord(text: "there", start: 2, end: 3)])
        tracker.resetAnchor()
        tracker.observePauseTimings([TimedSpeechWord(text: "resume", start: 8, end: 9)])
        tracker.observePauseTimings([TimedSpeechWord(text: "uncertain", start: 11, end: 12, timingSource: .estimatedWithinSegment), TimedSpeechWord(text: "again", start: 15, end: 16)])
        let sample = try XCTUnwrap(tracker.sample(activeSeconds: 30, at: .distantPast))
        XCTAssertEqual(sample.pauseCount, 1); XCTAssertEqual(sample.medianPauseSeconds, 1)
        var profile = PersonalPaceProfile(); profile.record(sample)
        XCTAssertEqual(profile.usualPauseSeconds, 1)
    }

}
