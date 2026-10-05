import Foundation

public enum PaceHint: Equatable, Sendable {
    case speedUp
    case slowDown
    case overtime

    public var title: String {
        switch self {
        case .speedUp: return "Speed up · A little behind"
        case .slowDown: return "Slow down · You have time"
        case .overtime: return "Over time · Wrap up"
        }
    }
}

public enum PaceGuidance {
    /// Compares words read with the share of the allotted time already used.
    public static func hint(elapsed: TimeInterval, duration: TimeInterval, progress: Double, previous: PaceHint? = nil) -> PaceHint? {
        guard duration >= 60, duration.isFinite, elapsed >= 0, elapsed.isFinite,
              progress.isFinite, progress >= 0, progress < 1 else { return nil }
        if elapsed > duration { return .overtime }

        // A short grace period and a meaningful gap keep the cue from flickering
        // after each word or appearing during the opening sentence.
        guard elapsed >= max(15, duration * 0.08) else { return nil }
        let gapInSeconds = (progress - elapsed / duration) * duration
        let threshold = max(12, duration * 0.08)
        // A smaller exit threshold avoids alternating warnings around the boundary.
        if previous == .speedUp, gapInSeconds <= -threshold * 0.6 { return .speedUp }
        if previous == .slowDown, gapInSeconds >= threshold * 0.6 { return .slowDown }
        if gapInSeconds <= -threshold { return .speedUp }
        if gapInSeconds >= threshold { return .slowDown }
        return nil
    }
}

/// Time-based confirmation and reminders, independent of speech callback frequency.
/// A warning must persist for three seconds; reminders are at least 12 seconds apart.
public struct PaceFeedback: Sendable {
    public private(set) var hint: PaceHint?
    private var pending: PaceHint?
    private var pendingSince: Date?
    private var lastPulse: Date?

    public init() {}
    public mutating func reset() { self = Self() }

    @discardableResult public mutating func update(_ candidate: PaceHint?, at date: Date) -> Bool {
        if candidate != hint {
            if candidate != pending || pendingSince == nil {
                pending = candidate
                pendingSince = date
            }
            if candidate == .overtime || date.timeIntervalSince(pendingSince ?? date) >= 3 {
                hint = candidate
                pendingSince = nil
                lastPulse = hint == nil ? nil : date
                return hint != nil
            }
            return false
        }
        pendingSince = nil
        guard hint != nil, lastPulse.map({ date.timeIntervalSince($0) >= 12 }) ?? true else { return false }
        lastPulse = date
        return true
    }
}
