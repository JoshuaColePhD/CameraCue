import XCTest
import AVFoundation
import CameraCueSpeech
import TeleprompterCore

/// Explicitly selected public fixture only. Never opens a microphone.
@MainActor final class PublicAudioPipelineTests: XCTestCase {
    func testCompressedAudioRetainsSpeechAndTimestamps() async throws {
        guard let path = ProcessInfo.processInfo.environment["CAMERACUE_PUBLIC_SPEECH_MANIFEST"] else {
            throw XCTSkip("Opt-in licensed audio integration test")
        }
        guard #available(macOS 26, *), await AnalyzerSpeechSession.supported() else { throw XCTSkip("Modern on-device speech unavailable") }
        let manifestURL = URL(fileURLWithPath: path)
        let manifest = try JSONDecoder().decode(SpeechCorpusManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
        let clip = try XCTUnwrap(manifest.clips.first)
        XCTAssertTrue(clip.isPublic)
        guard clip.isPublic else { return }
        let original = manifestURL.deletingLastPathComponent().appendingPathComponent(clip.audioPath)
        let compressed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: compressed) }
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: original), presetName: AVAssetExportPresetAppleM4A))
        try await exporter.export(to: compressed, as: .m4a)
        let decoded = try AVAudioFile(forReading: compressed)
        XCTAssertGreaterThan(decoded.length, 0)
        let result = try await SpeechFileTranscriber.transcribe(url: compressed, engine: .analyzer, realtime: false, allowModelDownload: true, retainObservations: false)
        let words = TranscriptNormalizer.tokens(result.text), reference = TranscriptNormalizer.tokens(clip.script)
        let errors = WordErrorCounts.compare(reference: reference, recognized: words)
        XCTAssertLessThan(errors.rate, 0.4, "Public AAC integration smoke threshold; not a production ASR gate")
        XCTAssertGreaterThan(result.words.count, reference.count / 2)
        XCTAssertTrue(result.observations.allSatisfy(\.isValid))
        XCTAssertGreaterThan(result.words.last?.end ?? 0, clip.duration * 0.7)
        print("Public AAC pipeline: \(words.count) normalized words; WER \(errors.rate); timestamp provenance retained; no microphone used")
    }
}
