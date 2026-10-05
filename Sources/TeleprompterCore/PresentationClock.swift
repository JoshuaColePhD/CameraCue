import Foundation

public struct PresentationClock: Sendable {
    private var completed: TimeInterval = 0
    private var runningSince: Date?

    public init() {}

    public mutating func start(at date: Date = .now) {
        guard runningSince == nil else { return }
        runningSince = date
    }

    public mutating func pause(at date: Date = .now) {
        guard let runningSince else { return }
        completed += max(0, date.timeIntervalSince(runningSince))
        self.runningSince = nil
    }

    public mutating func reset() {
        completed = 0
        runningSince = nil
    }

    public func elapsed(at date: Date = .now) -> TimeInterval {
        completed + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    public func display(at date: Date = .now) -> String {
        Self.format(seconds: Int(elapsed(at: date)))
    }

    public func countdownDisplay(duration: TimeInterval, at date: Date = .now) -> String {
        let remaining = Int(max(0, duration)) - Int(elapsed(at: date))
        return remaining < 0 ? "-" + Self.format(seconds: -remaining) : Self.format(seconds: remaining)
    }

    private static func format(seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", minutes, seconds % 60)
    }
}
