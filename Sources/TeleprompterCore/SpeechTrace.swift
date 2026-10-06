import Foundation

public enum SpeechEngineID: String, Codable, Sendable, CaseIterable { case analyzer, legacy }
public enum WordTimingSource: String, Codable, Sendable {
    case manualReviewed, forcedAlignment, recognizer, estimatedWithinSegment
}
public struct TimedSpeechWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double?
    public var timingSource: WordTimingSource
    public init(text: String, start: Double, end: Double, confidence: Double? = nil, timingSource: WordTimingSource = .recognizer) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence; self.timingSource = timingSource
    }
}
/// Audio timestamps and callback delivery time have independent meanings. Both
/// are seconds relative to the session's start; offline delivery is not live lag.
public struct SpeechObservation: Codable, Equatable, Sendable {
    public var engine: SpeechEngineID
    public var text: String
    public var audioStart: Double
    public var audioEnd: Double
    public var deliveredAt: Double
    public var isFinal: Bool
    public var words: [TimedSpeechWord]
    public var sourceUptimeOrigin: Double?
    public init(engine: SpeechEngineID, text: String, audioStart: Double, audioEnd: Double, deliveredAt: Double, isFinal: Bool, words: [TimedSpeechWord], sourceUptimeOrigin: Double? = nil) {
        self.engine = engine; self.text = text; self.audioStart = audioStart; self.audioEnd = audioEnd; self.deliveredAt = deliveredAt; self.isFinal = isFinal; self.words = words; self.sourceUptimeOrigin = sourceUptimeOrigin
    }
    public var isValid: Bool {
        audioStart.isFinite && audioEnd.isFinite && deliveredAt.isFinite && audioStart >= 0 && audioEnd >= audioStart && deliveredAt >= 0 &&
        words.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= audioStart - 0.1 && $0.end >= $0.start && $0.end <= audioEnd + 0.1 }
    }
}

/// Iterative results replace overlapping audio, not append repeated text. Final
/// spans remain available for coaching, while the live aligner uses recent text.
public struct SpeechTranscriptLedger: Sendable {
    public private(set) var spans: [SpeechObservation] = []
    public init() {}
    public mutating func consume(_ observation: SpeechObservation) {
        guard observation.isValid, !observation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if spans.contains(where: { $0 == observation }) { return }
        // Never let a late volatile revision replace finalized audio.
        if !observation.isFinal && spans.contains(where: { $0.isFinal && Self.overlaps($0, observation) }) { return }
        spans.removeAll { Self.overlaps($0, observation) }
        spans.append(observation)
        spans.sort { $0.audioStart < $1.audioStart }
    }
    public var words: [TimedSpeechWord] { spans.flatMap(\.words) }
    public var text: String { spans.map(\.text).joined(separator: " ") }
    public var recentText: String { spans.suffix(12).map(\.text).joined(separator: " ") }
    private static func overlaps(_ a: SpeechObservation, _ b: SpeechObservation) -> Bool {
        abs(a.audioStart - b.audioStart) < 0.001 || (a.audioStart < b.audioEnd - 0.001 && b.audioStart < a.audioEnd - 0.001)
    }
}

public struct SpeechCorpusClip: Codable, Sendable {
    public var id: String
    public var speakerID: String
    public var split: String
    public var audioPath: String
    public var script: String
    public var referenceWords: [TimedSpeechWord]
    public var license: String
    public var sourceURL: String
    public var timingReviewer: String?
    public var timingReviewedAt: String?
    public var duration: Double
    public var isPublic: Bool
}
public struct SpeechCorpusManifest: Codable, Sendable {
    public var version: String
    public var clips: [SpeechCorpusClip]
    public func validate() throws {
        var ids = Set<String>(), speakers: [String: String] = [:]
        for clip in clips {
            guard ids.insert(clip.id).inserted, !clip.speakerID.isEmpty,
                  ["train", "validation", "held-out"].contains(clip.split), clip.duration.isFinite, clip.duration > 0,
                  !clip.referenceWords.isEmpty, !clip.license.isEmpty,
                  !clip.audioPath.hasPrefix("/"), !clip.audioPath.split(separator: "/").contains("..") else { throw SpeechCorpusError.invalidClip(clip.id) }
            if let split = speakers[clip.speakerID], split != clip.split { throw SpeechCorpusError.speakerLeakage(clip.speakerID) }
            speakers[clip.speakerID] = clip.split
            var previous = -Double.infinity
            for word in clip.referenceWords {
                guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.start >= previous,
                      word.end >= word.start, word.end <= clip.duration + 0.05, !TranscriptNormalizer.tokens(word.text).isEmpty else { throw SpeechCorpusError.invalidClip(clip.id) }
                if word.timingSource == .manualReviewed && (clip.timingReviewer?.isEmpty != false || clip.timingReviewedAt?.isEmpty != false) { throw SpeechCorpusError.unreviewedTiming(clip.id) }
                previous = word.start
            }
            guard TranscriptNormalizer.tokens(clip.script) == clip.referenceWords.flatMap({ TranscriptNormalizer.tokens($0.text) }) else { throw SpeechCorpusError.invalidClip(clip.id) }
        }
        guard !clips.isEmpty else { throw SpeechCorpusError.invalidClip("empty corpus") }
    }
}
public enum SpeechCorpusError: Error, CustomStringConvertible {
    case invalidClip(String), speakerLeakage(String), unreviewedTiming(String)
    public var description: String {
        switch self {
        case .invalidClip(let id): "Invalid corpus clip: \(id)"
        case .speakerLeakage(let id): "Speaker appears in more than one split: \(id)"
        case .unreviewedTiming(let id): "Manual timing needs a reviewer and review date: \(id)"
        }
    }
}
