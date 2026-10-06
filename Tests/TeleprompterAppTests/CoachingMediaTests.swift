import XCTest
import AppKit
import SwiftUI
import TeleprompterCore
@testable import TeleprompterApp

@MainActor final class CoachingMediaTests: XCTestCase {
    func testRenderFeedbackWithIsolatedTranscript() async throws {
        guard let path = ProcessInfo.processInfo.environment["CAMERACUE_ML_MEDIA"] else { throw XCTSkip("Opt-in isolated feedback renderer") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: RecordingSpeechAnalysisStore.sidecar(for: video)) }
        let words = [TimedSpeechWord(text: "Your", start: 0, end: 0.4), TimedSpeechWord(text: "voice", start: 0.4, end: 0.8), TimedSpeechWord(text: "leads", start: 0.8, end: 1.2),
                     TimedSpeechWord(text: "Your", start: 5, end: 5.4), TimedSpeechWord(text: "voice", start: 5.4, end: 5.8), TimedSpeechWord(text: "leads", start: 5.8, end: 6.2)]
        try RecordingSpeechAnalysisStore.write(RecordingSpeechAnalysis(videoFilename: video.lastPathComponent, analyzedAt: .now, engine: .analyzer, words: words,
                                                                       script: nil, containsProvisionalWords: false), video: video)
        let view = NSHostingView(rootView: RecordingCoachingView(url: video) { _ in }.padding(24).frame(width: 700, height: 430).background(StudioPalette.canvas).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(600))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("coaching.png"))
    }
}
