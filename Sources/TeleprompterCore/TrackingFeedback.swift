import Foundation

public enum VoiceTrackingState: String, Equatable, Sendable {
    case listening = "Listening", following = "Following", recovering = "Finding your place"
}

/// Only distinct transcript evidence can enter recovery. A silent pause is not a miss.
public struct TrackingFeedback: Sendable {
    public private(set) var state: VoiceTrackingState = .listening
    private var lastTranscript = ""
    private var missBegan: Date?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func consume(_ text: String, confidence: AlignmentConfidence, at date: Date) {
        let normalized = TranscriptNormalizer.tokens(text).joined(separator: " ")
        guard !normalized.isEmpty, normalized != lastTranscript else { return }
        lastTranscript = normalized
        if confidence != .low {
            state = .following
            missBegan = nil
        } else {
            if let missBegan, date.timeIntervalSince(missBegan) >= 2 { state = .recovering }
            else if missBegan == nil { missBegan = date }
        }
    }
}
