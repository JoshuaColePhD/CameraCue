import Foundation

public struct PersonalPaceSample: Codable, Equatable, Sendable {
    public let words: Int
    public let activeSeconds: Double
    public let recordedAt: Date
    public var wordsPerMinute: Double { Double(words) * 60 / activeSeconds }
    public init(words: Int, activeSeconds: Double, recordedAt: Date) { self.words = words; self.activeSeconds = activeSeconds; self.recordedAt = recordedAt }
}
public struct PersonalPaceProfile: Codable, Equatable, Sendable {
    public private(set) var samples: [PersonalPaceSample] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case samples }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for sample in try container.decode([PersonalPaceSample].self, forKey: .samples) { record(sample) }
    }
    public mutating func record(_ sample: PersonalPaceSample) {
        guard (30...100_000).contains(sample.words), sample.activeSeconds.isFinite, (15...14_400).contains(sample.activeSeconds), (35...320).contains(sample.wordsPerMinute) else { return }
        samples.append(sample); samples = Array(samples.suffix(20))
    }
    public var usualWordsPerMinute: Double? {
        guard !samples.isEmpty else { return nil }
        let rates = samples.map(\.wordsPerMinute).sorted()
        return rates[rates.count / 2]
    }
}
public struct PersonalPaceEstimate: Equatable, Sendable {
    public let remainingSeconds: Double
    public let effectiveWordsPerMinute: Double
    public let usesPersonalHistory: Bool
    public let reliableWindows: Int
    public func hint(remainingTarget: Double, threshold: Double = 15) -> PaceHint? {
        if remainingTarget < 0 { return .overtime }
        if remainingSeconds > remainingTarget + threshold { return .speedUp }
        if remainingSeconds < remainingTarget - threshold { return .slowDown }
        return nil
    }
}
/// Only short, reliable forward movements contribute. Skips/restarts rebase the
/// anchor so jumping in the script cannot falsely teach a faster speaking rate.
public struct PersonalPaceTracker: Sendable {
    public private(set) var reliableWords = 0
    private var position: Int?
    private var elapsed: Double?
    private var windowWords = 0
    private var windowSeconds = 0.0
    private var rates: [Double] = []
    public init() {}
    public mutating func resetAnchor() { position = nil; elapsed = nil; windowWords = 0; windowSeconds = 0 }
    public mutating func observe(position next: Int, activeElapsed: Double, reliable: Bool) {
        guard activeElapsed.isFinite, activeElapsed >= 0 else { return }
        guard reliable else { resetAnchor(); return }
        guard let position, let elapsed else { self.position = next; self.elapsed = activeElapsed; return }
        let words = next - position, seconds = activeElapsed - elapsed
        if words == 0 { return }
        defer { self.position = next; self.elapsed = activeElapsed }
        guard words > 0, words <= 12, seconds > 0, seconds <= 20 else { windowWords = 0; windowSeconds = 0; return }
        reliableWords += words; windowWords += words; windowSeconds += seconds
        if windowSeconds >= 8, windowWords >= 10 {
            let rate = Double(windowWords) * 60 / windowSeconds
            if (35...320).contains(rate) { rates.append(rate); rates = Array(rates.suffix(8)) }
            windowWords = 0; windowSeconds = 0
        }
    }
    public func estimate(remainingWords: Int, profile: PersonalPaceProfile) -> PersonalPaceEstimate? {
        guard remainingWords > 0 else { return nil }
        let personal = profile.usualWordsPerMinute
        let current = rates.isEmpty ? nil : rates.sorted()[rates.count / 2]
        guard let rate = current ?? personal else { return nil }
        // Blend seconds/word to avoid overweighting a single very fast window.
        let secondsPerWord: Double
        if let current, let personal {
            let weight = min(0.8, Double(rates.count) / 6)
            secondsPerWord = weight * 60 / current + (1 - weight) * 60 / personal
        } else { secondsPerWord = 60 / rate }
        return PersonalPaceEstimate(remainingSeconds: Double(remainingWords) * secondsPerWord, effectiveWordsPerMinute: 60 / secondsPerWord,
                                    usesPersonalHistory: personal != nil, reliableWindows: rates.count)
    }
    public func sample(activeSeconds: Double, at date: Date) -> PersonalPaceSample? {
        guard rates.count >= 2, reliableWords >= 30, activeSeconds >= 15 else { return nil }
        let median = rates.sorted()[rates.count / 2]
        return PersonalPaceSample(words: reliableWords, activeSeconds: Double(reliableWords) * 60 / median, recordedAt: date)
    }
}
