import Foundation
import TeleprompterCore

enum PresentationPhase: Equatable { case ready, starting, countIn, running, paused, finished }

struct TakeSummary: Equatable {
    let activeDuration: TimeInterval
    let timerDuration: TimeInterval
    let targetDuration: TimeInterval?
    let timerWasReset: Bool
    var durationText: String { Self.time(activeDuration) }
    var comparison: String {
        guard let targetDuration else { return "Count up · \(Self.time(timerDuration))" }
        let difference = Int(timerDuration) - Int(targetDuration)
        let prefix = timerWasReset ? "Last timer segment: " : ""
        if difference == 0 { return prefix + "Right on target" }
        return prefix + "\(Self.time(Double(abs(difference)))) \(difference > 0 ? "over" : "under") target"
    }
    static func time(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// All live surfaces render this same immutable state. No view infers playback from its own timer.
struct PresentationSnapshot: Equatable {
    let phase: PresentationPhase
    let status: String
    let lineID: Int
    /// Last reliably matched spoken token; nil until speech establishes a position.
    let wordIndex: Int?
    let timerText: String
    let overtime: Bool
    let countIn: Int?
    let warning: PaceHint?
    let recovering: Bool
    let cue: String
    let problem: String?
    let canFinish: Bool
    let summary: TakeSummary?
    var playbackTitle: String {
        switch phase {
        case .running: return "Pause"
        case .paused: return "Resume"
        case .starting: return "Wait"
        case .countIn: return "Cancel"
        case .finished: return "Again"
        case .ready: return "Play"
        }
    }
    var playbackSymbol: String {
        switch phase {
        case .running: return "pause.fill"
        case .starting: return "ellipsis"
        case .countIn: return "xmark"
        case .finished: return "arrow.counterclockwise"
        default: return "play.fill"
        }
    }
    var banner: String? { recovering ? "Finding your place · Keep reading or pause to recover" : warning?.title }
}
