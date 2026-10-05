import XCTest
import AppKit
import SwiftUI
import TeleprompterCore
@testable import TeleprompterApp

@MainActor final class WordHighlightTests: XCTestCase {
    func testSpeechAdvancesWordByWordAndHoldsDuringSilenceRecoveryAndPause() async throws {
        var date = Date(timeIntervalSince1970: 1000)
        let capture = WordCapture()
        let model = TeleprompterModel(capture: capture, defaults: nil, now: { date })
        model.load(ScriptRecord(id: UUID(), title: "Words", body: "One little horse.\nTwo mighty walls.\nThree brave soldiers.", modifiedAt: date))
        XCTAssertNil(model.snapshot(at: date).wordIndex)
        await model.start()
        XCTAssertNil(model.snapshot(at: date).wordIndex, "Listening alone cannot imply that a word was read")
        for count in 2...6 {
            capture.onTranscript?(model.document.tokens.prefix(count).joined(separator: " "))
            XCTAssertEqual(model.snapshot(at: date).wordIndex, count - 1)
        }
        let held = model.snapshot(at: date).wordIndex
        date += 30
        model.refreshPaceFeedback(at: date)
        XCTAssertEqual(model.snapshot(at: date).wordIndex, held, "Silence never advances the highlight")
        capture.onTranscript?(model.document.tokens.prefix(6).joined(separator: " "))
        capture.onTranscript?("")
        XCTAssertEqual(model.snapshot(at: date).wordIndex, held, "Duplicate and empty partials hold")
        capture.onTranscript?("purple submarine")
        date += 3
        capture.onTranscript?("purple submarine beneath a rainbow")
        XCTAssertTrue(model.snapshot(at: date).recovering)
        XCTAssertEqual(model.snapshot(at: date).wordIndex, held)
        model.pause()
        capture.onTranscript?(model.document.tokens.joined(separator: " "))
        XCTAssertEqual(model.snapshot(at: date).wordIndex, held, "Pause freezes speech highlights")
        await model.start()
        capture.onTranscript?("three brave soldiers")
        XCTAssertFalse(model.snapshot(at: date).recovering)
        XCTAssertEqual(model.snapshot(at: date).wordIndex, 8)
        XCTAssertEqual(model.phase, .running, "Last word does not finish the take")
        model.resetTimer()
        XCTAssertEqual(model.snapshot(at: date).wordIndex, 8)
        model.finish()
        XCTAssertNil(model.snapshot(at: date).wordIndex)
        model.reset()
        XCTAssertNil(model.snapshot(at: date).wordIndex)
    }

    func testPhraseRecoveryAndModeChangesClearStaleHighlights() async {
        let capture = WordCapture()
        let followed = TeleprompterModel(capture: capture, defaults: nil)
        let script = ScriptRecord(id: UUID(), title: "Recovery", body: "One little horse.\nTwo mighty walls.", modifiedAt: .now)
        followed.load(script)
        await followed.start()
        capture.onTranscript?("one little horse")
        XCTAssertEqual(followed.snapshot(at: .now).wordIndex, 2)
        followed.pause()
        followed.selectPhrase(followed.document.lineID(forToken: 3))
        XCTAssertNil(followed.snapshot(at: .now).wordIndex)
        await followed.start()
        capture.onTranscript?("two mighty walls")
        XCTAssertEqual(followed.snapshot(at: .now).wordIndex, 5)
        followed.pause(); followed.mode = .manual
        XCTAssertNil(followed.snapshot(at: .now).wordIndex)
        await followed.start()
        capture.onTranscript?("one little horse")
        XCTAssertNil(followed.snapshot(at: .now).wordIndex)
        followed.pause(); followed.mode = .voice
        XCTAssertNil(followed.snapshot(at: .now).wordIndex, "Switching back must wait for a new match")
        followed.load(ScriptRecord(id: UUID(), title: "New", body: "A different script.", modifiedAt: .now))
        XCTAssertNil(followed.followedWordIndex)
    }

    func testUnicodeContractionsRepeatedOccurrencesAndSourcePreservation() {
        let source = "Wait… we’re ready, café 🚀 — go! Go!"
        let moment = PerformanceMoment(lineID: 0, phrase: "Go", tone: .coral, scale: .huge, pauseAfter: true, tokenAnchor: TokenAnchor(6..<7))
        for token in [1, 2] {
            let segments = PerformanceText.segments(source, moments: [moment], tokenOffset: 0, activeWordIndex: token)
            XCTAssertEqual(segments.map(\.text).joined(), source)
            XCTAssertEqual(segments.filter { $0.readingState == .current }.map(\.text).joined(), "we’re")
            XCTAssertEqual(segments.filter { $0.readingState == .spoken }.map(\.text).joined(), "Wait… ")
        }
        let repeated = PerformanceText.segments(source, moments: [moment], tokenOffset: 0, activeWordIndex: 6)
        XCTAssertEqual(repeated.map(\.text).joined(), source)
        let current = repeated.filter { $0.readingState == .current }
        XCTAssertEqual(current.map(\.text).joined(), "Go")
        XCTAssertEqual(current.first?.moment, moment, "Highlight overlays rather than discarding delivery formatting")
        let ready = PerformanceText.segments(source, moments: [moment], tokenOffset: 0, activeWordIndex: nil)
        XCTAssertTrue(ready.allSatisfy { $0.readingState == .upcoming })
        XCTAssertEqual(ready.map(\.text).joined(), source)
    }

    func testHighlightUsesGlobalWordOccurrenceAcrossCueAndReadingLines() {
        let document = ScriptDocument("Same words.\n[Pause.]\nSame words again.")
        let rows = document.lines.filter { !$0.spokenText.isEmpty }.map {
            PerformanceText.segments($0.spokenText, moments: [], tokenOffset: $0.tokenRange.lowerBound, activeWordIndex: 3)
        }
        XCTAssertTrue(rows[0].allSatisfy { $0.readingState == .spoken })
        XCTAssertEqual(rows[1].filter { $0.readingState == .current }.map(\.text).joined(), "words")
        XCTAssertEqual(rows[1].filter { $0.readingState == .upcoming }.map(\.text).joined(), " again.")
        let next = PerformanceText.segments("Same words again.", moments: [], tokenOffset: 2, activeWordIndex: 0)
        XCTAssertTrue(next.allSatisfy { $0.readingState == .upcoming })
    }

    func testColorChangesNeverChangeTextMetricsOrWrapping() {
        _ = NSApplication.shared
        let source = "We waited for TEN YEARS."
        let moment = PerformanceMoment(lineID: 0, phrase: "TEN YEARS", tone: .coral, scale: .huge, pauseAfter: false, tokenAnchor: TokenAnchor(3..<5))
        func size(_ word: Int?) -> CGSize {
            let text = PerformanceText.make(source, moments: [moment], tokenOffset: 0,
                base: CuePalette.cream, accent: CuePalette.lavender, baseSize: 29, intensity: 1,
                maximumScale: 1.06, activeWordIndex: word)
                .font(.system(size: 29, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center).frame(width: 230).fixedSize(horizontal: false, vertical: true)
            let host = NSHostingView(rootView: text)
            return host.fittingSize
        }
        let original = size(nil)
        XCTAssertGreaterThan(original.height, 0)
        for word in 0...6 {
            XCTAssertEqual(size(word).width, original.width, accuracy: 0.5)
            XCTAssertEqual(size(word).height, original.height, accuracy: 0.5)
        }
    }
}

@MainActor private final class WordCapture: SpeechCapturing {
    var state: SpeechFollower.State = .idle
    var onTranscript: ((String) -> Void)?
    var onUnexpectedStop: (() -> Void)?
    func start() async { state = .listening }
    func pause() { state = .paused }
    func stop() { state = .idle }
}
