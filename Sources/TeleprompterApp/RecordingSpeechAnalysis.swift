import Foundation
import TeleprompterCore

struct RecordingSpeechAnalysis: Codable, Sendable {
    var schemaVersion = 1
    var videoFilename: String
    var analyzedAt: Date
    var engine: SpeechEngineID
    var words: [TimedSpeechWord]
    var script: String?
    var containsProvisionalWords: Bool
}

enum RecordingSpeechAnalysisStore {
    static func sidecar(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("cameracue.speech.json") }
    static func read(video: URL) throws -> RecordingSpeechAnalysis? {
        let path = sidecar(for: video)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 12_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let bytes = try Data(contentsOf: path)
        guard bytes.count <= 12_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let data = try JSONDecoder().decode(RecordingSpeechAnalysis.self, from: bytes)
        try validate(data, video: video)
        return data
    }
    static func write(_ analysis: RecordingSpeechAnalysis, video: URL) throws {
        var analysis = analysis; analysis.videoFilename = video.lastPathComponent
        try validate(analysis, video: video)
        let bytes = try JSONEncoder().encode(analysis)
        guard bytes.count <= 12_000_000 else { throw CocoaError(.fileWriteUnknown) }
        try bytes.write(to: sidecar(for: video), options: .atomic)
    }
    private static func validate(_ data: RecordingSpeechAnalysis, video: URL) throws {
        guard data.schemaVersion == 1, data.videoFilename == video.lastPathComponent, data.words.count <= 100_000,
              (data.script?.utf8.count ?? 0) <= 1_000_000,
              data.words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 14_400 && $0.text.utf8.count <= 1_000 && ($0.confidence == nil || ($0.confidence!.isFinite && (0...1).contains($0.confidence!))) }) else { throw CocoaError(.fileReadCorruptFile) }
    }
}

struct RecordingSpeechCollector {
    private var ledger = SpeechTranscriptLedger()
    private(set) var engine: SpeechEngineID = .legacy
    private var mediaOrigin: Double?
    mutating func begin(at uptime: Double) { ledger = SpeechTranscriptLedger(); mediaOrigin = uptime }
    mutating func consume(_ event: SpeechObservation) {
        guard let mediaOrigin, let sourceOrigin = event.sourceUptimeOrigin, event.isValid, sourceOrigin.isFinite, mediaOrigin.isFinite, event.audioEnd + sourceOrigin - mediaOrigin <= 14_400 else { return }
        let offset = sourceOrigin - mediaOrigin
        var shifted = event
        shifted.audioStart = max(0, event.audioStart + offset)
        shifted.audioEnd = max(0, event.audioEnd + offset)
        shifted.deliveredAt = max(0, event.deliveredAt + offset)
        shifted.words = event.words.compactMap { word in
            guard word.end + offset > 0 else { return nil }
            var word = word; word.start = max(0, word.start + offset); word.end = max(0, word.end + offset); return word
        }
        guard !shifted.words.isEmpty else { return }
        engine = event.engine; ledger.consume(shifted)
    }
    func snapshot(script: String?) -> RecordingSpeechAnalysis? {
        guard !ledger.words.isEmpty else { return nil }
        return RecordingSpeechAnalysis(videoFilename: "", analyzedAt: .now, engine: engine, words: ledger.words, script: script,
                                       containsProvisionalWords: ledger.spans.contains { !$0.isFinal })
    }
}
